// ============================================================================
// blorp Runtime - Embedded Version
// ============================================================================

#define _GNU_SOURCE  // Required for memmem() on Linux/glibc

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <setjmp.h>
#include <assert.h>
#include <limits.h>
#include <math.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <signal.h>
#include <pthread.h>
#include <fcntl.h>
#include <poll.h>
#if defined(__linux__)
#include <sys/epoll.h>
#endif
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/event.h>
#endif
#if defined(__linux__)
#include <sys/random.h>
#endif

#if defined(__has_feature)
  #if __has_feature(address_sanitizer)
    #define BLORP_ASAN 1
  #endif
#endif
#if defined(__SANITIZE_ADDRESS__)
  #define BLORP_ASAN 1
#endif

#if defined(MSG_NOSIGNAL)
#define BLORP_TCP_SEND_FLAGS MSG_NOSIGNAL
#else
#define BLORP_TCP_SEND_FLAGS 0
#endif

#define BLORP_TCP_MAX_READ_BYTES (64L * 1024L * 1024L)

// ============================================================================
// SIMD Platform Detection and Abstractions
// ============================================================================
//
// This section provides platform-abstracted SIMD operations for Vector types.
// Tier 1 (N <= 4): Inline SIMD via macros (single instruction per operation)
// Tier 2 (4 < N <= 256): SIMD loop functions (vectorized loops)
// Tier 3 (N > 256): Scalar loops with compiler hints
//

// Platform detection and SIMD header includes
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
    #define BLORP_ARCH_X86 1
    #if defined(__AVX2__)
        #define BLORP_SIMD_AVX2 1
        #define BLORP_SIMD_WIDTH 256
        #include <immintrin.h>
    #elif defined(__AVX__)
        #define BLORP_SIMD_AVX 1
        #define BLORP_SIMD_WIDTH 256
        #include <immintrin.h>
    #elif defined(__SSE4_1__)
        #define BLORP_SIMD_SSE4 1
        #define BLORP_SIMD_WIDTH 128
        #include <smmintrin.h>
    #elif defined(__SSE2__)
        #define BLORP_SIMD_SSE2 1
        #define BLORP_SIMD_WIDTH 128
        #include <emmintrin.h>
    #else
        #define BLORP_SIMD_NONE 1
        #define BLORP_SIMD_WIDTH 0
    #endif
#elif defined(__aarch64__) || defined(_M_ARM64)
    #define BLORP_ARCH_ARM64 1
    #if defined(__ARM_NEON)
        #define BLORP_SIMD_NEON 1
        #define BLORP_SIMD_WIDTH 128
        #include <arm_neon.h>
    #else
        #define BLORP_SIMD_NONE 1
        #define BLORP_SIMD_WIDTH 0
    #endif
#else
    #define BLORP_SIMD_NONE 1
    #define BLORP_SIMD_WIDTH 0
#endif

// ============================================================================
// SIMD Type Abstractions (Tier 1: N <= 4)
// ============================================================================
// These types map to native SIMD registers when available

#if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
    // x86 SSE: 128-bit registers
    typedef __m128  blorp_simd_f32x4;   // 4 x float
    typedef __m128d blorp_simd_f64x2;   // 2 x double
    typedef __m128i blorp_simd_i32x4;   // 4 x int32
    typedef __m128i blorp_simd_i64x2;   // 2 x int64

    // Load/store operations
    #define BLORP_SIMD_LOAD_F32X4(ptr)      _mm_loadu_ps(ptr)
    #define BLORP_SIMD_STORE_F32X4(ptr, v)  _mm_storeu_ps(ptr, v)
    #define BLORP_SIMD_LOAD_F64X2(ptr)      _mm_loadu_pd(ptr)
    #define BLORP_SIMD_STORE_F64X2(ptr, v)  _mm_storeu_pd(ptr, v)
    #define BLORP_SIMD_LOAD_I32X4(ptr)      _mm_loadu_si128((const __m128i*)(ptr))
    #define BLORP_SIMD_STORE_I32X4(ptr, v)  _mm_storeu_si128((__m128i*)(ptr), v)

    // Arithmetic: float32 x 4
    #define BLORP_SIMD_ADD_F32X4(a, b)      _mm_add_ps(a, b)
    #define BLORP_SIMD_SUB_F32X4(a, b)      _mm_sub_ps(a, b)
    #define BLORP_SIMD_MUL_F32X4(a, b)      _mm_mul_ps(a, b)
    #define BLORP_SIMD_DIV_F32X4(a, b)      _mm_div_ps(a, b)

    // Arithmetic: float64 x 2
    #define BLORP_SIMD_ADD_F64X2(a, b)      _mm_add_pd(a, b)
    #define BLORP_SIMD_SUB_F64X2(a, b)      _mm_sub_pd(a, b)
    #define BLORP_SIMD_MUL_F64X2(a, b)      _mm_mul_pd(a, b)
    #define BLORP_SIMD_DIV_F64X2(a, b)      _mm_div_pd(a, b)

    // Arithmetic: int32 x 4
    #define BLORP_SIMD_ADD_I32X4(a, b)      _mm_add_epi32(a, b)
    #define BLORP_SIMD_SUB_I32X4(a, b)      _mm_sub_epi32(a, b)
    #if defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        #define BLORP_SIMD_MUL_I32X4(a, b)  _mm_mullo_epi32(a, b)
    #else
        // SSE2 doesn't have native 32-bit multiply - emulate with shuffles
        static inline __m128i blorp_simd_mul_i32x4_sse2(__m128i a, __m128i b) {
            __m128i tmp1 = _mm_mul_epu32(a, b);
            __m128i tmp2 = _mm_mul_epu32(_mm_srli_si128(a, 4), _mm_srli_si128(b, 4));
            return _mm_unpacklo_epi32(
                _mm_shuffle_epi32(tmp1, _MM_SHUFFLE(0, 0, 2, 0)),
                _mm_shuffle_epi32(tmp2, _MM_SHUFFLE(0, 0, 2, 0))
            );
        }
        #define BLORP_SIMD_MUL_I32X4(a, b)  blorp_simd_mul_i32x4_sse2(a, b)
    #endif
    // No native SIMD integer division - use scalar fallback

    // Set operations (for literals)
    #define BLORP_SIMD_SET_F32X4(a, b, c, d) _mm_set_ps(d, c, b, a)
    #define BLORP_SIMD_SET_F64X2(a, b)       _mm_set_pd(b, a)
    #define BLORP_SIMD_SET_I32X4(a, b, c, d) _mm_set_epi32(d, c, b, a)

    // Zero vectors
    #define BLORP_SIMD_ZERO_F32X4()         _mm_setzero_ps()
    #define BLORP_SIMD_ZERO_F64X2()         _mm_setzero_pd()
    #define BLORP_SIMD_ZERO_I32X4()         _mm_setzero_si128()

    // Comparison for safe division (returns mask)
    #define BLORP_SIMD_CMPEQ_F32X4(a, b)    _mm_cmpeq_ps(a, b)
    #define BLORP_SIMD_CMPEQ_F64X2(a, b)    _mm_cmpeq_pd(a, b)

    // Blend/select based on mask
    #if defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        #define BLORP_SIMD_BLEND_F32X4(a, b, mask) _mm_blendv_ps(a, b, mask)
        #define BLORP_SIMD_BLEND_F64X2(a, b, mask) _mm_blendv_pd(a, b, mask)
    #else
        // SSE2 fallback: use bitwise ops
        #define BLORP_SIMD_BLEND_F32X4(a, b, mask) \
            _mm_or_ps(_mm_and_ps(mask, b), _mm_andnot_ps(mask, a))
        #define BLORP_SIMD_BLEND_F64X2(a, b, mask) \
            _mm_or_pd(_mm_and_pd(mask, b), _mm_andnot_pd(mask, a))
    #endif

#elif defined(BLORP_SIMD_NEON)
    // ARM NEON: 128-bit registers
    typedef float32x4_t blorp_simd_f32x4;   // 4 x float
    typedef float64x2_t blorp_simd_f64x2;   // 2 x double
    typedef int32x4_t   blorp_simd_i32x4;   // 4 x int32
    typedef int64x2_t   blorp_simd_i64x2;   // 2 x int64

    // Load/store operations
    #define BLORP_SIMD_LOAD_F32X4(ptr)      vld1q_f32(ptr)
    #define BLORP_SIMD_STORE_F32X4(ptr, v)  vst1q_f32(ptr, v)
    #define BLORP_SIMD_LOAD_F64X2(ptr)      vld1q_f64(ptr)
    #define BLORP_SIMD_STORE_F64X2(ptr, v)  vst1q_f64(ptr, v)
    #define BLORP_SIMD_LOAD_I32X4(ptr)      vld1q_s32(ptr)
    #define BLORP_SIMD_STORE_I32X4(ptr, v)  vst1q_s32(ptr, v)

    // Arithmetic: float32 x 4
    #define BLORP_SIMD_ADD_F32X4(a, b)      vaddq_f32(a, b)
    #define BLORP_SIMD_SUB_F32X4(a, b)      vsubq_f32(a, b)
    #define BLORP_SIMD_MUL_F32X4(a, b)      vmulq_f32(a, b)
    #define BLORP_SIMD_DIV_F32X4(a, b)      vdivq_f32(a, b)

    // Arithmetic: float64 x 2
    #define BLORP_SIMD_ADD_F64X2(a, b)      vaddq_f64(a, b)
    #define BLORP_SIMD_SUB_F64X2(a, b)      vsubq_f64(a, b)
    #define BLORP_SIMD_MUL_F64X2(a, b)      vmulq_f64(a, b)
    #define BLORP_SIMD_DIV_F64X2(a, b)      vdivq_f64(a, b)

    // Arithmetic: int32 x 4
    #define BLORP_SIMD_ADD_I32X4(a, b)      vaddq_s32(a, b)
    #define BLORP_SIMD_SUB_I32X4(a, b)      vsubq_s32(a, b)
    #define BLORP_SIMD_MUL_I32X4(a, b)      vmulq_s32(a, b)

    // Set operations (for literals)
    static inline float32x4_t blorp_simd_set_f32x4(float a, float b, float c, float d) {
        float data[4] = {a, b, c, d};
        return vld1q_f32(data);
    }
    #define BLORP_SIMD_SET_F32X4(a, b, c, d) blorp_simd_set_f32x4(a, b, c, d)
    static inline float64x2_t blorp_simd_set_f64x2(double a, double b) {
        double data[2] = {a, b};
        return vld1q_f64(data);
    }
    #define BLORP_SIMD_SET_F64X2(a, b)       blorp_simd_set_f64x2(a, b)
    static inline int32x4_t blorp_simd_set_i32x4(int32_t a, int32_t b, int32_t c, int32_t d) {
        int32_t data[4] = {a, b, c, d};
        return vld1q_s32(data);
    }
    #define BLORP_SIMD_SET_I32X4(a, b, c, d) blorp_simd_set_i32x4(a, b, c, d)

    // Zero vectors
    #define BLORP_SIMD_ZERO_F32X4()         vdupq_n_f32(0.0f)
    #define BLORP_SIMD_ZERO_F64X2()         vdupq_n_f64(0.0)
    #define BLORP_SIMD_ZERO_I32X4()         vdupq_n_s32(0)

    // Comparison for safe division
    #define BLORP_SIMD_CMPEQ_F32X4(a, b)    vceqq_f32(a, b)
    #define BLORP_SIMD_CMPEQ_F64X2(a, b)    vceqq_f64(a, b)

    // Blend/select based on mask
    #define BLORP_SIMD_BLEND_F32X4(a, b, mask) vbslq_f32(mask, b, a)
    #define BLORP_SIMD_BLEND_F64X2(a, b, mask) vbslq_f64(mask, b, a)

#else
    // No SIMD: scalar fallback types (for compilation on unsupported platforms)
    typedef struct { float v[4]; }  blorp_simd_f32x4;
    typedef struct { double v[2]; } blorp_simd_f64x2;
    typedef struct { int32_t v[4]; } blorp_simd_i32x4;
    typedef struct { int64_t v[2]; } blorp_simd_i64x2;

    // Scalar fallback implementations
    static inline blorp_simd_f32x4 blorp_simd_add_f32x4_scalar(blorp_simd_f32x4 a, blorp_simd_f32x4 b) {
        blorp_simd_f32x4 r; for (int i=0; i<4; i++) r.v[i] = a.v[i] + b.v[i]; return r;
    }
    static inline blorp_simd_f32x4 blorp_simd_sub_f32x4_scalar(blorp_simd_f32x4 a, blorp_simd_f32x4 b) {
        blorp_simd_f32x4 r; for (int i=0; i<4; i++) r.v[i] = a.v[i] - b.v[i]; return r;
    }
    static inline blorp_simd_f32x4 blorp_simd_mul_f32x4_scalar(blorp_simd_f32x4 a, blorp_simd_f32x4 b) {
        blorp_simd_f32x4 r; for (int i=0; i<4; i++) r.v[i] = a.v[i] * b.v[i]; return r;
    }
    static inline blorp_simd_f32x4 blorp_simd_div_f32x4_scalar(blorp_simd_f32x4 a, blorp_simd_f32x4 b) {
        blorp_simd_f32x4 r; for (int i=0; i<4; i++) r.v[i] = b.v[i] == 0.0f ? 0.0f : a.v[i] / b.v[i]; return r;
    }
    #define BLORP_SIMD_ADD_F32X4(a, b)      blorp_simd_add_f32x4_scalar(a, b)
    #define BLORP_SIMD_SUB_F32X4(a, b)      blorp_simd_sub_f32x4_scalar(a, b)
    #define BLORP_SIMD_MUL_F32X4(a, b)      blorp_simd_mul_f32x4_scalar(a, b)
    #define BLORP_SIMD_DIV_F32X4(a, b)      blorp_simd_div_f32x4_scalar(a, b)

    static inline blorp_simd_f32x4 blorp_simd_set_f32x4_scalar(float a, float b, float c, float d) {
        blorp_simd_f32x4 r; r.v[0] = a; r.v[1] = b; r.v[2] = c; r.v[3] = d; return r;
    }
    #define BLORP_SIMD_SET_F32X4(a, b, c, d) blorp_simd_set_f32x4_scalar(a, b, c, d)
    #define BLORP_SIMD_ZERO_F32X4()         blorp_simd_set_f32x4_scalar(0, 0, 0, 0)
#endif

// ============================================================================
// Checked Arithmetic for Allocation Sizes
// ============================================================================

static size_t blorp_checked_mul(long a, long b) {
    if (a < 0 || b < 0) {
        fprintf(stderr, "blorp: negative allocation size (%ld * %ld)\\n", a, b);
        exit(1);
    }
    if (a > 0 && b > 0 && (size_t)a > SIZE_MAX / (size_t)b) {
        fprintf(stderr, "blorp: allocation size overflow (%ld * %ld)\\n", a, b);
        exit(1);
    }
    return (size_t)a * (size_t)b;
}

static size_t blorp_checked_add(size_t a, size_t b) {
    if (a > SIZE_MAX - b) {
        fprintf(stderr, "blorp: allocation size overflow (%zu + %zu)\\n", a, b);
        exit(1);
    }
    return a + b;
}

void* blorp_malloc_checked(size_t size) {
    void* ptr = malloc(size);
    if (!ptr) {
        fprintf(stderr, "blorp: out of memory (malloc %zu bytes)\\n", size);
        exit(1);
    }
    return ptr;
}

static void* blorp_calloc_checked(size_t count, size_t size) {
    void* ptr = calloc(count, size);
    if (!ptr) {
        fprintf(stderr, "blorp: out of memory (calloc %zu * %zu bytes)\\n", count, size);
        exit(1);
    }
    return ptr;
}

// ============================================================================
// Memory Statistics (forward declaration for SIMD tracking)
// ============================================================================

// Forward declaration of ARC object header (full definition reused by SIMD section below).
// Keep this header compact: every managed value starts with it, so extra fields
// are paid by strings, records, boxed values, closures, lists, dicts, and more.
// Stats and leak-report metadata stay in cold side tables.
typedef struct blorp_Object_s {
    _Atomic long refcount;
    uint32_t alloc_class;
    uint32_t destructor_id;
} blorp_Object;

#define BLORP_ALLOC_CLASS_DIRECT UINT32_MAX
typedef void (*blorp_destructor_fn)(void*);

// User-facing struct for blorp_get_mem_stats return value
// Uses blorp_Object header so it participates in ARC (codegen emits retain/release)
typedef struct {
    blorp_Object header;
    long total_allocations;
    long total_releases;
    long current_objects;
    long bytes_allocated;
} blorp_MemStats;

// User-facing struct for scheduler instrumentation snapshots.
// Field order must match std/instrumentation.brp's SchedulerStats record.
typedef struct {
    blorp_Object header;
    long tasks_spawned;
    long fibers_created;
    long fibers_reused;
    long fibers_completed;
    long fiber_resumes;
    long fiber_parks;
    long fiber_schedule_transitions;
    long runnable_enqueues;
    long run_queue_pops;
    long timer_inserts;
    long timer_expirations;
    long reactor_control_wakes;
    long reactor_poll_wakes;
    long reactor_ready_events;
    long reactor_waiter_wakes;
    long stack_allocations;
    long stack_reuses;
    long work_steals;
    long run_queue_lock_contentions;
    long timer_lock_contentions;
    long worker_count;
    long runnable_count;
    long timers_pending;
} blorp_SchedulerStats;

typedef enum {
    BLORP_TCP_HANDLE_LISTENER = 1,
    BLORP_TCP_HANDLE_STREAM = 2
} blorp_TcpHandleKind;

typedef enum {
    BLORP_TCP_STATE_OPEN = 1,
    BLORP_TCP_STATE_CLOSING = 2,
    BLORP_TCP_STATE_CLOSED = 3
} blorp_TcpState;

typedef enum {
    BLORP_IO_WAIT_NONE = 0,
    BLORP_IO_WAIT_ACCEPT = 1,
    BLORP_IO_WAIT_CONNECT = 2,
    BLORP_IO_WAIT_READ = 3,
    BLORP_IO_WAIT_WRITE = 4
} blorp_IoWaitKind;

typedef enum {
    BLORP_IO_WAKE_NONE = 0,
    BLORP_IO_WAKE_READY = 1,
    BLORP_IO_WAKE_TIMEOUT = 2,
    BLORP_IO_WAKE_CANCELLED = 3,
    BLORP_IO_WAKE_CLOSED = 4
} blorp_IoWakeReason;

typedef struct blorp_IoWaiter {
    _Atomic long refcount;
    blorp_IoWaitKind kind;
    blorp_IoWakeReason wake_reason;
    struct blorp_Fiber* fiber;
    uint64_t generation;
    uint64_t deadline_ns;
    long deadline_index;
    bool cancelled;
    bool installed;
    bool deadline_queued;
    struct blorp_TcpInner* owner;
    struct blorp_TcpInner* deadline_owner;
    struct blorp_IoWaiter* next;
} blorp_IoWaiter;

typedef struct {
    blorp_IoWaiter* head;
    blorp_IoWaiter* tail;
} blorp_IoWaiterList;

typedef struct {
    blorp_IoWaiter** items;
    size_t len;
    size_t cap;
    pthread_mutex_t lock;
} blorp_IoDeadlineQueue;

typedef struct {
    blorp_IoWaiter* waiter;
    struct blorp_TcpInner* owner;
} blorp_IoDeadlineEntry;

typedef struct blorp_TcpInner {
    _Atomic long refcount;
    int fd;
    uint64_t generation;
    blorp_TcpHandleKind kind;
    blorp_TcpState state;
    long default_timeout_ms;
    pthread_mutex_t mutex;
    blorp_IoWaiter* accept_waiter;
    blorp_IoWaiter* connect_waiter;
    blorp_IoWaiter* read_waiter;
    blorp_IoWaiter* write_waiter;
    bool write_active;
} blorp_TcpInner;

struct blorp_TcpListener {
    blorp_Object header;
    blorp_TcpInner* inner;
};
typedef struct blorp_TcpListener blorp_TcpListener;

struct blorp_TcpStream {
    blorp_Object header;
    blorp_TcpInner* inner;
};
typedef struct blorp_TcpStream blorp_TcpStream;

static _Atomic uint64_t blorp_tcp_next_generation = 1;
static void blorp_tcp_suppress_sigpipe(int fd);
static int blorp_io_reactor_set_nonblocking(int fd);
static int blorp_runtime_set_cloexec(int fd);
static int blorp_runtime_socket_cloexec(int domain, int type, int protocol);
static int blorp_runtime_accept_cloexec(
    int fd,
    struct sockaddr* addr,
    socklen_t* addr_len
);
static int blorp_runtime_pipe_cloexec_nonblock(int fds[2]);

typedef enum {
    BLORP_IO_BACKEND_KQUEUE = 1,
    BLORP_IO_BACKEND_EPOLL = 2,
    BLORP_IO_BACKEND_POLL = 3
} blorp_IoBackendKind;

typedef enum {
    BLORP_IO_INTEREST_READ = 1,
    BLORP_IO_INTEREST_WRITE = 2
} blorp_IoInterest;

typedef struct blorp_IoRegistration {
    int fd;
    uint64_t generation;
    int interests;
    int ready_events;
    blorp_TcpInner* inner;
    struct blorp_IoRegistration* next;
} blorp_IoRegistration;

typedef struct blorp_IoReactor {
    pthread_mutex_t mutex;
    pthread_cond_t ready_cond;
    pthread_t thread;
    _Atomic bool started;
    bool thread_started;
    bool shutdown;
    int control_read_fd;
    int control_write_fd;
    blorp_IoBackendKind backend;
    blorp_IoRegistration* registrations;
} blorp_IoReactor;

typedef struct {
    int fd;
    uint64_t generation;
    int interests;
} blorp_IoRegistrationSnapshot;

static blorp_IoReactor __blorp_io_reactor = {
    .started = false,
    .thread_started = false,
    .shutdown = false,
    .control_read_fd = -1,
    .control_write_fd = -1,
    .backend = BLORP_IO_BACKEND_POLL,
    .registrations = NULL
};
static pthread_once_t __blorp_io_reactor_once = PTHREAD_ONCE_INIT;
static int __blorp_io_reactor_init_error = 0;

static bool blorp_io_reactor_is_started(void) {
    return atomic_load_explicit(
        &__blorp_io_reactor.started, memory_order_acquire);
}

static void blorp_io_reactor_set_started(bool started) {
    atomic_store_explicit(
        &__blorp_io_reactor.started, started, memory_order_release);
}

static blorp_IoDeadlineQueue __blorp_io_deadline_queue = {
    .items = NULL,
    .len = 0,
    .cap = 0,
};
static pthread_once_t __blorp_io_deadline_queue_once = PTHREAD_ONCE_INIT;

// Thread-safe global counters (atomic for concurrent alloc/release).
// Note: ++/-- on _Atomic long is atomic per C11 (equivalent to atomic_fetch_add/sub).
static struct {
    _Atomic long total_allocations;
    _Atomic long total_releases;
    _Atomic long current_objects;
    _Atomic long bytes_allocated;
    _Atomic unsigned long epoch;
} global_mem_stats = {0, 0, 0, 0, 0};

static struct {
    _Atomic long tasks_spawned;
    _Atomic long fibers_created;
    _Atomic long fibers_reused;
    _Atomic long fibers_completed;
    _Atomic long fiber_resumes;
    _Atomic long fiber_parks;
    _Atomic long fiber_schedule_transitions;
    _Atomic long runnable_enqueues;
    _Atomic long run_queue_pops;
    _Atomic long timer_inserts;
    _Atomic long timer_expirations;
    _Atomic long reactor_control_wakes;
    _Atomic long reactor_poll_wakes;
    _Atomic long reactor_ready_events;
    _Atomic long reactor_waiter_wakes;
    _Atomic long stack_allocations;
    _Atomic long stack_reuses;
    _Atomic long work_steals;
    _Atomic long run_queue_lock_contentions;
    _Atomic long timer_lock_contentions;
} global_scheduler_stats = {0};

static _Atomic int __blorp_scheduler_stats_enabled = 0;

static inline bool __blorp_scheduler_stats_active(void) {
    return atomic_load_explicit(
        &__blorp_scheduler_stats_enabled, memory_order_relaxed) != 0;
}

static inline void __blorp_scheduler_stat_inc(_Atomic long* counter) {
    if (__blorp_scheduler_stats_active()) {
        atomic_fetch_add_explicit(counter, 1, memory_order_relaxed);
    }
}

static inline void __blorp_scheduler_stat_add(_Atomic long* counter, long delta) {
    if (delta > 0 && __blorp_scheduler_stats_active()) {
        atomic_fetch_add_explicit(counter, delta, memory_order_relaxed);
    }
}

static inline void __blorp_scheduler_stat_lock(
    pthread_mutex_t* lock,
    _Atomic long* contention_counter
) {
    if (!__blorp_scheduler_stats_active()) {
        pthread_mutex_lock(lock);
        return;
    }
    if (pthread_mutex_trylock(lock) == 0) return;
    atomic_fetch_add_explicit(contention_counter, 1, memory_order_relaxed);
    pthread_mutex_lock(lock);
}

// Stats tracking is enabled by explicit runtime requests such as leak checking
// and memory.stats/reset_stats. When disabled (default in release/benchmark
// builds), alloc/release skip counter updates entirely.
static bool __blorp_stats_enabled = false;

// ============================================================================
// Cold allocation metadata (stats and leak reports)
// ============================================================================
// Allocation metadata is kept out of the hot object header. It is only created
// while memory stats or leak tracking are active; normal execution only stores a
// small pool class in the header so release can recycle small objects.
typedef struct blorp_AllocMeta_s {
    blorp_Object* object;
    size_t alloc_size;
    unsigned long stats_epoch;
    bool stats_tracked;
    bool live_linked;
    const char* type_tag;
    struct blorp_AllocMeta_s* live_next;
    struct blorp_AllocMeta_s* live_prev;
    struct blorp_AllocMeta_s* hash_next;
} blorp_AllocMeta;

#define BLORP_ALLOC_META_SLOTS 16384
static blorp_AllocMeta* __alloc_meta_table[BLORP_ALLOC_META_SLOTS];
static blorp_AllocMeta __alloc_live_sentinel = {0};
static bool __leak_tracking_enabled = false;
static pthread_mutex_t __alloc_meta_mutex = PTHREAD_MUTEX_INITIALIZER;

static inline bool __alloc_meta_enabled(void) {
    return __blorp_stats_enabled || __leak_tracking_enabled;
}

static inline size_t __alloc_meta_slot(const blorp_Object* obj) {
    return (((uintptr_t)obj) >> 4) & (BLORP_ALLOC_META_SLOTS - 1);
}

static blorp_AllocMeta* __alloc_meta_find_locked(const blorp_Object* obj) {
    size_t slot = __alloc_meta_slot(obj);
    for (blorp_AllocMeta* meta = __alloc_meta_table[slot]; meta; meta = meta->hash_next) {
        if (meta->object == obj) return meta;
    }
    return NULL;
}

static void __alloc_meta_insert(blorp_Object* obj, size_t alloc_size, bool stats_tracked) {
    if (!__alloc_meta_enabled()) return;
    blorp_AllocMeta* meta = (blorp_AllocMeta*)malloc(sizeof(blorp_AllocMeta));
    if (!meta) {
        fprintf(stderr, "blorp: out of memory (allocation metadata)\n");
        exit(1);
    }
    meta->object = obj;
    meta->alloc_size = alloc_size;
    meta->stats_epoch = atomic_load(&global_mem_stats.epoch);
    meta->stats_tracked = stats_tracked;
    meta->live_linked = __leak_tracking_enabled;
    meta->type_tag = NULL;
    pthread_mutex_lock(&__alloc_meta_mutex);
    size_t slot = __alloc_meta_slot(obj);
    meta->hash_next = __alloc_meta_table[slot];
    __alloc_meta_table[slot] = meta;
    if (meta->live_linked) {
        meta->live_next = __alloc_live_sentinel.live_next;
        meta->live_prev = &__alloc_live_sentinel;
        if (__alloc_live_sentinel.live_next)
            __alloc_live_sentinel.live_next->live_prev = meta;
        __alloc_live_sentinel.live_next = meta;
    } else {
        meta->live_next = NULL;
        meta->live_prev = NULL;
    }
    pthread_mutex_unlock(&__alloc_meta_mutex);
}

static blorp_AllocMeta* __alloc_meta_take(blorp_Object* obj) {
    if (!__alloc_meta_enabled()) return NULL;
    pthread_mutex_lock(&__alloc_meta_mutex);
    size_t slot = __alloc_meta_slot(obj);
    blorp_AllocMeta** link = &__alloc_meta_table[slot];
    while (*link && (*link)->object != obj) {
        link = &(*link)->hash_next;
    }
    blorp_AllocMeta* meta = *link;
    if (meta) {
        *link = meta->hash_next;
        if (meta->live_linked && meta->live_prev)
            meta->live_prev->live_next = meta->live_next;
        if (meta->live_linked && meta->live_next)
            meta->live_next->live_prev = meta->live_prev;
    }
    pthread_mutex_unlock(&__alloc_meta_mutex);
    return meta;
}

static void __alloc_meta_set_type_tag(blorp_Object* obj, const char* tag) {
    if (!__alloc_meta_enabled()) return;
    pthread_mutex_lock(&__alloc_meta_mutex);
    blorp_AllocMeta* meta = __alloc_meta_find_locked(obj);
    if (meta) meta->type_tag = tag;
    pthread_mutex_unlock(&__alloc_meta_mutex);
}

// ============================================================================
// Destructor registry
// ============================================================================
// Most heap objects do not need a destructor. For the ones that do, store a
// compact id in the hot header and keep the function pointer once per type/call
// site in this process-wide registry.
#define BLORP_DESTRUCTOR_SLOTS 4096
static blorp_destructor_fn __blorp_destructors[BLORP_DESTRUCTOR_SLOTS];
static _Atomic uint32_t __blorp_destructor_count = 1;  // id 0 means no destructor
static pthread_mutex_t __blorp_destructor_mutex = PTHREAD_MUTEX_INITIALIZER;

uint32_t blorp_get_destructor_id(_Atomic uint32_t* cache, blorp_destructor_fn fn) {
    if (!fn) return 0;

    uint32_t cached = atomic_load_explicit(cache, memory_order_acquire);
    if (cached != 0) return cached;

    pthread_mutex_lock(&__blorp_destructor_mutex);
    cached = atomic_load_explicit(cache, memory_order_relaxed);
    if (cached == 0) {
        uint32_t count = atomic_load_explicit(&__blorp_destructor_count, memory_order_relaxed);
        for (uint32_t i = 1; i < count; i++) {
            if (__blorp_destructors[i] == fn) {
                cached = i;
                break;
            }
        }
        if (cached == 0) {
            if (count >= BLORP_DESTRUCTOR_SLOTS) {
                fprintf(stderr, "blorp: too many destructor functions\n");
                exit(1);
            }
            cached = count;
            __blorp_destructors[cached] = fn;
            atomic_store_explicit(&__blorp_destructor_count, count + 1, memory_order_release);
        }
        atomic_store_explicit(cache, cached, memory_order_release);
    }
    pthread_mutex_unlock(&__blorp_destructor_mutex);
    return cached;
}

void blorp_set_destructor_id(void* obj, uint32_t id) {
    if (obj) ((blorp_Object*)obj)->destructor_id = id;
}

static inline blorp_destructor_fn blorp_destructor_for_id(uint32_t id) {
    uint32_t count = atomic_load_explicit(&__blorp_destructor_count, memory_order_acquire);
    return id < count ? __blorp_destructors[id] : NULL;
}

#define BLORP_SET_DESTRUCTOR(ptr, fn) do { \
    static _Atomic uint32_t __blorp_destructor_id = 0; \
    blorp_set_destructor_id((void*)(ptr), \
        blorp_get_destructor_id(&__blorp_destructor_id, (blorp_destructor_fn)(fn))); \
} while (0)

__attribute__((constructor))
static void __blorp_init_stats_flag(void) {
    __blorp_stats_enabled =
#ifdef BLORP_RUNTIME_LEAK_CHECK_STRICT
        true;
#else
        false;
#endif
    __leak_tracking_enabled = __blorp_stats_enabled;
    __alloc_live_sentinel.live_next = NULL;
    __alloc_live_sentinel.live_prev = NULL;
}

static inline void blorp_init_object_header(blorp_Object* header,
                                            uint32_t alloc_class,
                                            size_t alloc_size) {
    atomic_store_explicit(&header->refcount, 1, memory_order_relaxed);
    header->alloc_class = alloc_class;
    header->destructor_id = 0;
    __alloc_meta_insert(header, alloc_size, true);
    if (__blorp_stats_enabled) {
        global_mem_stats.total_allocations++;
        global_mem_stats.current_objects++;
        global_mem_stats.bytes_allocated += (long)alloc_size;
    }
}

// ============================================================================
// SIMD Aligned Memory Allocation (for Tier 2)
// ============================================================================

static inline void* blorp_simd_alloc(size_t size) {
    void* ptr;
    #if defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        // AVX requires 32-byte alignment
        ptr = aligned_alloc(32, ((size + 31) / 32) * 32);
    #elif defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_NEON)
        // SSE/NEON require 16-byte alignment
        ptr = aligned_alloc(16, ((size + 15) / 16) * 16);
    #else
        ptr = malloc(size);
    #endif
    if (!ptr) { fprintf(stderr, "blorp: out of memory (simd_alloc %zu bytes)\n", size); abort(); }
    return ptr;
}

// ============================================================================
// SIMD Safe Division (handles divide-by-zero with mask)
// ============================================================================

#if !defined(BLORP_SIMD_NONE)
// Safe division: returns 0 where divisor is 0
static inline blorp_simd_f32x4 blorp_simd_safe_div_f32x4(blorp_simd_f32x4 a, blorp_simd_f32x4 b) {
    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        __m128 zero = _mm_setzero_ps();
        __m128 mask = _mm_cmpeq_ps(b, zero);  // mask is all-1s where b==0
        __m128 result = _mm_div_ps(a, b);
        return BLORP_SIMD_BLEND_F32X4(result, zero, mask);  // select 0 where b==0
    #elif defined(BLORP_SIMD_NEON)
        float32x4_t zero = vdupq_n_f32(0.0f);
        uint32x4_t mask = vceqq_f32(b, zero);
        float32x4_t result = vdivq_f32(a, b);
        return vbslq_f32(mask, zero, result);
    #endif
}

static inline blorp_simd_f64x2 blorp_simd_safe_div_f64x2(blorp_simd_f64x2 a, blorp_simd_f64x2 b) {
    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        __m128d zero = _mm_setzero_pd();
        __m128d mask = _mm_cmpeq_pd(b, zero);
        __m128d result = _mm_div_pd(a, b);
        return BLORP_SIMD_BLEND_F64X2(result, zero, mask);
    #elif defined(BLORP_SIMD_NEON)
        float64x2_t zero = vdupq_n_f64(0.0);
        uint64x2_t mask = vceqq_f64(b, zero);
        float64x2_t result = vdivq_f64(a, b);
        return vbslq_f64(mask, zero, result);
    #endif
}
#endif

// ============================================================================
// Tier 2 SIMD Vector Operations (4 < N <= 256)
// ============================================================================
// These functions operate on blorp_Vector and use SIMD loops internally

// Forward declarations for ARC types used by SIMD functions
// (blorp_Object is defined above in Memory Statistics section)
// storage_mode: pointer/word slots, inline byte storage, raw Float64 slots,
// raw Float32 slots, or compact integer/enum slots.
#ifndef BLORP_VECTOR_STORAGE_POINTER
#define BLORP_VECTOR_STORAGE_POINTER 0
#define BLORP_VECTOR_STORAGE_INLINE 1
#define BLORP_VECTOR_STORAGE_F64 2
#define BLORP_VECTOR_STORAGE_F32 3
#define BLORP_VECTOR_STORAGE_PACKED 4
#define BLORP_VECTOR_STORAGE_I64 5
#endif
typedef struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[5]; void* data[]; } blorp_Vector;

// Tier 2: SIMD-accelerated vector add for float32
blorp_Vector* blorp_simd_vector_add_f32(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(float))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 4;
    result->storage_mode = BLORP_VECTOR_STORAGE_F32;

    float* da = (float*)a->data;
    float* db = (float*)b->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;  // Round down to multiple of 4
        for (long i = 0; i < simd_len; i += 4) {
            __m128 va = _mm_loadu_ps(&da[i]);
            __m128 vb = _mm_loadu_ps(&db[i]);
            _mm_storeu_ps(&dr[i], _mm_add_ps(va, vb));
        }
        // Scalar remainder
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        for (long i = 0; i < simd_len; i += 4) {
            float32x4_t va = vld1q_f32(&da[i]);
            float32x4_t vb = vld1q_f32(&db[i]);
            vst1q_f32(&dr[i], vaddq_f32(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_sub_f32(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(float))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 4;
    result->storage_mode = BLORP_VECTOR_STORAGE_F32;

    float* da = (float*)a->data;
    float* db = (float*)b->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;
        for (long i = 0; i < simd_len; i += 4) {
            __m128 va = _mm_loadu_ps(&da[i]);
            __m128 vb = _mm_loadu_ps(&db[i]);
            _mm_storeu_ps(&dr[i], _mm_sub_ps(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        for (long i = 0; i < simd_len; i += 4) {
            float32x4_t va = vld1q_f32(&da[i]);
            float32x4_t vb = vld1q_f32(&db[i]);
            vst1q_f32(&dr[i], vsubq_f32(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_mul_f32(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(float))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 4;
    result->storage_mode = BLORP_VECTOR_STORAGE_F32;

    float* da = (float*)a->data;
    float* db = (float*)b->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;
        for (long i = 0; i < simd_len; i += 4) {
            __m128 va = _mm_loadu_ps(&da[i]);
            __m128 vb = _mm_loadu_ps(&db[i]);
            _mm_storeu_ps(&dr[i], _mm_mul_ps(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        for (long i = 0; i < simd_len; i += 4) {
            float32x4_t va = vld1q_f32(&da[i]);
            float32x4_t vb = vld1q_f32(&db[i]);
            vst1q_f32(&dr[i], vmulq_f32(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_div_f32(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(float))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 4;
    result->storage_mode = BLORP_VECTOR_STORAGE_F32;

    float* da = (float*)a->data;
    float* db = (float*)b->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;
        __m128 zero = _mm_setzero_ps();
        for (long i = 0; i < simd_len; i += 4) {
            __m128 va = _mm_loadu_ps(&da[i]);
            __m128 vb = _mm_loadu_ps(&db[i]);
            __m128 mask = _mm_cmpeq_ps(vb, zero);
            __m128 div_result = _mm_div_ps(va, vb);
            _mm_storeu_ps(&dr[i], BLORP_SIMD_BLEND_F32X4(div_result, zero, mask));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        float32x4_t zero = vdupq_n_f32(0.0f);
        for (long i = 0; i < simd_len; i += 4) {
            float32x4_t va = vld1q_f32(&da[i]);
            float32x4_t vb = vld1q_f32(&db[i]);
            uint32x4_t mask = vceqq_f32(vb, zero);
            float32x4_t div_result = vdivq_f32(va, vb);
            vst1q_f32(&dr[i], vbslq_f32(mask, zero, div_result));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
        }
    #endif
    return result;
}

// Tier 2: SIMD-accelerated vector operations for float64 (double)
blorp_Vector* blorp_simd_vector_add_f64(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(double))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 8;
    result->storage_mode = BLORP_VECTOR_STORAGE_F64;

    double* da = (double*)a->data;
    double* db = (double*)b->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;  // Round down to multiple of 2
        for (long i = 0; i < simd_len; i += 2) {
            __m128d va = _mm_loadu_pd(&da[i]);
            __m128d vb = _mm_loadu_pd(&db[i]);
            _mm_storeu_pd(&dr[i], _mm_add_pd(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        for (long i = 0; i < simd_len; i += 2) {
            float64x2_t va = vld1q_f64(&da[i]);
            float64x2_t vb = vld1q_f64(&db[i]);
            vst1q_f64(&dr[i], vaddq_f64(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] + db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_sub_f64(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(double))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 8;
    result->storage_mode = BLORP_VECTOR_STORAGE_F64;

    double* da = (double*)a->data;
    double* db = (double*)b->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        for (long i = 0; i < simd_len; i += 2) {
            __m128d va = _mm_loadu_pd(&da[i]);
            __m128d vb = _mm_loadu_pd(&db[i]);
            _mm_storeu_pd(&dr[i], _mm_sub_pd(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        for (long i = 0; i < simd_len; i += 2) {
            float64x2_t va = vld1q_f64(&da[i]);
            float64x2_t vb = vld1q_f64(&db[i]);
            vst1q_f64(&dr[i], vsubq_f64(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] - db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_mul_f64(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(double))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 8;
    result->storage_mode = BLORP_VECTOR_STORAGE_F64;

    double* da = (double*)a->data;
    double* db = (double*)b->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        for (long i = 0; i < simd_len; i += 2) {
            __m128d va = _mm_loadu_pd(&da[i]);
            __m128d vb = _mm_loadu_pd(&db[i]);
            _mm_storeu_pd(&dr[i], _mm_mul_pd(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        for (long i = 0; i < simd_len; i += 2) {
            float64x2_t va = vld1q_f64(&da[i]);
            float64x2_t vb = vld1q_f64(&db[i]);
            vst1q_f64(&dr[i], vmulq_f64(va, vb));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = da[i] * db[i];
        }
    #endif
    return result;
}

blorp_Vector* blorp_simd_vector_div_f64(const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = (blorp_Vector*)blorp_simd_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(len, sizeof(double))));
    if (!result) return NULL;
    blorp_init_object_header(&result->header, BLORP_ALLOC_CLASS_DIRECT, 0);
    result->len = a->len <= len ? a->len : len;  // clamp: len <= capacity
    result->capacity = len;
    result->elem_release = NULL;
    result->elem_size = 8;
    result->storage_mode = BLORP_VECTOR_STORAGE_F64;

    double* da = (double*)a->data;
    double* db = (double*)b->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        __m128d zero = _mm_setzero_pd();
        for (long i = 0; i < simd_len; i += 2) {
            __m128d va = _mm_loadu_pd(&da[i]);
            __m128d vb = _mm_loadu_pd(&db[i]);
            __m128d mask = _mm_cmpeq_pd(vb, zero);
            __m128d div_result = _mm_div_pd(va, vb);
            _mm_storeu_pd(&dr[i], BLORP_SIMD_BLEND_F64X2(div_result, zero, mask));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        float64x2_t zero = vdupq_n_f64(0.0);
        for (long i = 0; i < simd_len; i += 2) {
            float64x2_t va = vld1q_f64(&da[i]);
            float64x2_t vb = vld1q_f64(&db[i]);
            uint64x2_t mask = vceqq_f64(vb, zero);
            float64x2_t div_result = vdivq_f64(va, vb);
            vst1q_f64(&dr[i], vbslq_f64(mask, zero, div_result));
        }
        for (long i = simd_len; i < len; i++) {
            dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
        }
    #else
        for (long i = 0; i < len; i++) {
            dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
        }
    #endif
    return result;
}

// Dispatcher function for SIMD vector operations
// op: 0=add, 1=sub, 2=mul, 3=div
// elem_type: 0=f32, 1=f64, 2=i32, 3=i64
blorp_Vector* blorp_simd_vector_op(int op, int elem_type, blorp_Vector* a, blorp_Vector* b) {
    if (elem_type == 0) {  // float32
        switch (op) {
            case 0: return blorp_simd_vector_add_f32(a, b);
            case 1: return blorp_simd_vector_sub_f32(a, b);
            case 2: return blorp_simd_vector_mul_f32(a, b);
            case 3: return blorp_simd_vector_div_f32(a, b);
        }
    } else if (elem_type == 1) {  // float64 (double)
        switch (op) {
            case 0: return blorp_simd_vector_add_f64(a, b);
            case 1: return blorp_simd_vector_sub_f64(a, b);
            case 2: return blorp_simd_vector_mul_f64(a, b);
            case 3: return blorp_simd_vector_div_f64(a, b);
        }
    }
    // Fallback to generic blorp_vector_op for unsupported types
    return NULL;
}

// ============================================================================
// SIMD Scalar Broadcast Operations (vector OP scalar, scalar OP vector)
// ============================================================================
// Forward declarations (defined in sections below)
blorp_Vector* blorp_vector_new_noinit(long);
blorp_Vector* blorp_vector_new_f32(long);  // Forward decl for COW SIMD F32 functions
bool blorp_is_unique(void* obj);  // Forward decl for COW SIMD functions
void blorp_release(void* obj);   // Forward decl for COW SIMD functions
static inline blorp_Vector* blorp_vector_new_like(const blorp_Vector* src);
static inline blorp_Vector* blorp_vector_new_f32_like(const blorp_Vector* src);
static inline void blorp_release_cow_input_if_copied(blorp_Vector* input, blorp_Vector* result) {
    if (result != input) blorp_release(input);
}

// Fused tensor update: result[i] = target[i] + input[i] * scale.
// Reuses target in place when uniquely owned; otherwise returns a fresh copy.
blorp_Vector* blorp_tensor_add_scaled_f64_cow(blorp_Vector* target, const blorp_Vector* input, double scale) {
    if (!target || !input) return NULL;
    long len = target->capacity < input->capacity ? target->capacity : input->capacity;
    int is_unique_target = blorp_is_unique(target);
    blorp_Vector* result = is_unique_target ? target : blorp_vector_new_like(target);

    double* dt = (double*)target->data;
    double* di = (double*)input->data;
    double* dr = (double*)result->data;
    for (long i = 0; i < len; i++) {
        dr[i] = dt[i] + di[i] * scale;
    }

    blorp_release_cow_input_if_copied(target, result);
    return result;
}

// Fused tensor update: result[i] = target[i] + input[i] * scale.
// Reuses target in place when uniquely owned; otherwise returns a fresh copy.
blorp_Vector* blorp_tensor_add_scaled_f32_cow(blorp_Vector* target, const blorp_Vector* input, float scale) {
    if (!target || !input) return NULL;
    long len = target->capacity < input->capacity ? target->capacity : input->capacity;
    int is_unique_target = blorp_is_unique(target);
    blorp_Vector* result = is_unique_target ? target : blorp_vector_new_f32_like(target);

    float* dt = (float*)target->data;
    float* di = (float*)input->data;
    float* dr = (float*)result->data;
    for (long i = 0; i < len; i++) {
        dr[i] = dt[i] + di[i] * scale;
    }

    blorp_release_cow_input_if_copied(target, result);
    return result;
}

// Forward: result[i] = v[i] OP scalar
blorp_Vector* blorp_simd_vector_scalar_op_f64(int op, const blorp_Vector* v, double scalar) {
    if (!v) return NULL;
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);

    double* dv = (double*)v->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        __m128d vs = _mm_set1_pd(scalar);
        switch (op) {
            case 0: // add
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_add_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1: // sub
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_sub_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2: // mul
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_mul_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: { // div — safe: scalar==0 → all zeros
                if (scalar == 0.0) {
                    memset(dr, 0, len * sizeof(double));
                } else {
                    for (long i = 0; i < simd_len; i += 2) {
                        _mm_storeu_pd(&dr[i], _mm_div_pd(_mm_loadu_pd(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default:
                for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        float64x2_t vs = vdupq_n_f64(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vaddq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vsubq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vmulq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: {
                if (scalar == 0.0) {
                    memset(dr, 0, len * sizeof(double));
                } else {
                    for (long i = 0; i < simd_len; i += 2) {
                        vst1q_f64(&dr[i], vdivq_f64(vld1q_f64(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default:
                for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = dv[i] + scalar; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = dv[i] - scalar; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = dv[i] * scalar; break;
            case 3:
                if (scalar == 0.0) { memset(dr, 0, len * sizeof(double)); }
                else { for (long i = 0; i < len; i++) dr[i] = dv[i] / scalar; }
                break;
            default: for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #endif
    return result;
}

// Reversed: result[i] = scalar OP v[i]
blorp_Vector* blorp_simd_vector_scalar_op_rev_f64(int op, const blorp_Vector* v, double scalar) {
    if (!v) return NULL;
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);

    double* dv = (double*)v->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        __m128d vs = _mm_set1_pd(scalar);
        switch (op) {
            case 0: // add (commutative, same as forward)
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_add_pd(vs, _mm_loadu_pd(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar + dv[i];
                break;
            case 1: // scalar - v[i]
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_sub_pd(vs, _mm_loadu_pd(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar - dv[i];
                break;
            case 2: // mul (commutative)
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_mul_pd(vs, _mm_loadu_pd(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar * dv[i];
                break;
            case 3: { // scalar / v[i] — per-element safe division
                __m128d zero = _mm_setzero_pd();
                for (long i = 0; i < simd_len; i += 2) {
                    __m128d vv = _mm_loadu_pd(&dv[i]);
                    __m128d mask = _mm_cmpeq_pd(vv, zero);
                    __m128d div_result = _mm_div_pd(vs, vv);
                    _mm_storeu_pd(&dr[i], BLORP_SIMD_BLEND_F64X2(div_result, zero, mask));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (dv[i] == 0.0) ? 0.0 : scalar / dv[i];
                }
                break;
            }
            default:
                for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        float64x2_t vs = vdupq_n_f64(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vaddq_f64(vs, vld1q_f64(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar + dv[i];
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vsubq_f64(vs, vld1q_f64(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar - dv[i];
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vmulq_f64(vs, vld1q_f64(&dv[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = scalar * dv[i];
                break;
            case 3: {
                float64x2_t zero = vdupq_n_f64(0.0);
                for (long i = 0; i < simd_len; i += 2) {
                    float64x2_t vv = vld1q_f64(&dv[i]);
                    uint64x2_t mask = vceqq_f64(vv, zero);
                    float64x2_t div_result = vdivq_f64(vs, vv);
                    vst1q_f64(&dr[i], vbslq_f64(mask, zero, div_result));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (dv[i] == 0.0) ? 0.0 : scalar / dv[i];
                }
                break;
            }
            default:
                for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = scalar + dv[i]; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = scalar - dv[i]; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = scalar * dv[i]; break;
            case 3:
                for (long i = 0; i < len; i++) {
                    dr[i] = (dv[i] == 0.0) ? 0.0 : scalar / dv[i];
                }
                break;
            default: for (long i = 0; i < len; i++) dr[i] = dv[i];
        }
    #endif
    return result;
}

// ============================================================================
// COW (Copy-on-Write) Invariants
// ============================================================================
//
// 1. COW builtins always consume their first parameter — either via in-place
//    mutation (unique refcount) or copy+release (shared). Codegen marks the
//    param as cow_consumed and skips cleanup release.
//
// 2. Same-pointer guard — When replacing a container element with the same
//    pointer, skip both release and retain to prevent use-after-free.
//    Applied in: blorp_dict_insert.
//
// 3. Move optimization — For `x = f(x, ...)` where x is the first arg,
//    codegen pre-decrements refcount so the callee's entry retain restores
//    it, enabling in-place COW ops. Only applies to first argument position.
//
// ============================================================================
// COW (Copy-on-Write) SIMD Vector Operations
// When input is uniquely owned, write in-place; otherwise allocate new.
// ============================================================================

// COW element-wise: result[i] = a[i] OP b[i] (in-place when a is unique)
// op: 0=add, 1=sub, 2=mul, 3=div
blorp_Vector* blorp_simd_vector_op_f64_cow(int op, blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    int is_unique_a = blorp_is_unique(a);
    blorp_Vector* result;
    if (is_unique_a) {
        result = a;
    } else {
        result = blorp_vector_new_like(a);
    }

    double* da = (double*)a->data;
    double* db = (double*)b->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_add_pd(_mm_loadu_pd(&da[i]), _mm_loadu_pd(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] + db[i];
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_sub_pd(_mm_loadu_pd(&da[i]), _mm_loadu_pd(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] - db[i];
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_mul_pd(_mm_loadu_pd(&da[i]), _mm_loadu_pd(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] * db[i];
                break;
            case 3: {
                __m128d zero = _mm_setzero_pd();
                for (long i = 0; i < simd_len; i += 2) {
                    __m128d va = _mm_loadu_pd(&da[i]);
                    __m128d vb = _mm_loadu_pd(&db[i]);
                    __m128d mask = _mm_cmpeq_pd(vb, zero);
                    __m128d div_result = _mm_div_pd(va, vb);
                    _mm_storeu_pd(&dr[i], BLORP_SIMD_BLEND_F64X2(div_result, zero, mask));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
                }
                break;
            }
            default:
                break;
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vaddq_f64(vld1q_f64(&da[i]), vld1q_f64(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] + db[i];
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vsubq_f64(vld1q_f64(&da[i]), vld1q_f64(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] - db[i];
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vmulq_f64(vld1q_f64(&da[i]), vld1q_f64(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] * db[i];
                break;
            case 3: {
                float64x2_t zero = vdupq_n_f64(0.0);
                for (long i = 0; i < simd_len; i += 2) {
                    float64x2_t va = vld1q_f64(&da[i]);
                    float64x2_t vb = vld1q_f64(&db[i]);
                    uint64x2_t mask = vceqq_f64(vb, zero);
                    float64x2_t div_result = vdivq_f64(va, vb);
                    vst1q_f64(&dr[i], vbslq_f64(mask, zero, div_result));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
                }
                break;
            }
            default:
                break;
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = da[i] + db[i]; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = da[i] - db[i]; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = da[i] * db[i]; break;
            case 3:
                for (long i = 0; i < len; i++) {
                    dr[i] = (db[i] == 0.0) ? 0.0 : da[i] / db[i];
                }
                break;
            default: break;
        }
    #endif
    blorp_release_cow_input_if_copied(a, result);
    return result;
}

// COW element-wise F32: result[i] = a[i] OP b[i] (in-place when a is unique)
blorp_Vector* blorp_simd_vector_op_f32_cow(int op, blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long len = a->capacity < b->capacity ? a->capacity : b->capacity;
    int is_unique_a = blorp_is_unique(a);
    blorp_Vector* result;
    if (is_unique_a) {
        result = a;
    } else {
        result = blorp_vector_new_f32_like(a);
    }

    float* da = (float*)a->data;
    float* db = (float*)b->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_add_ps(_mm_loadu_ps(&da[i]), _mm_loadu_ps(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] + db[i];
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_sub_ps(_mm_loadu_ps(&da[i]), _mm_loadu_ps(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] - db[i];
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_mul_ps(_mm_loadu_ps(&da[i]), _mm_loadu_ps(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] * db[i];
                break;
            case 3: {
                __m128 zero = _mm_setzero_ps();
                for (long i = 0; i < simd_len; i += 4) {
                    __m128 va = _mm_loadu_ps(&da[i]);
                    __m128 vb = _mm_loadu_ps(&db[i]);
                    __m128 mask = _mm_cmpeq_ps(vb, zero);
                    __m128 div_result = _mm_div_ps(va, vb);
                    _mm_storeu_ps(&dr[i], BLORP_SIMD_BLEND_F32X4(div_result, zero, mask));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
                }
                break;
            }
            default:
                break;
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vaddq_f32(vld1q_f32(&da[i]), vld1q_f32(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] + db[i];
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vsubq_f32(vld1q_f32(&da[i]), vld1q_f32(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] - db[i];
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vmulq_f32(vld1q_f32(&da[i]), vld1q_f32(&db[i])));
                }
                for (long i = simd_len; i < len; i++) dr[i] = da[i] * db[i];
                break;
            case 3: {
                float32x4_t zero = vdupq_n_f32(0.0f);
                for (long i = 0; i < simd_len; i += 4) {
                    float32x4_t va = vld1q_f32(&da[i]);
                    float32x4_t vb = vld1q_f32(&db[i]);
                    uint32x4_t mask = vceqq_f32(vb, zero);
                    float32x4_t div_result = vdivq_f32(va, vb);
                    vst1q_f32(&dr[i], vbslq_f32(mask, zero, div_result));
                }
                for (long i = simd_len; i < len; i++) {
                    dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
                }
                break;
            }
            default:
                break;
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = da[i] + db[i]; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = da[i] - db[i]; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = da[i] * db[i]; break;
            case 3:
                for (long i = 0; i < len; i++) {
                    dr[i] = (db[i] == 0.0f) ? 0.0f : da[i] / db[i];
                }
                break;
            default: break;
        }
    #endif
    blorp_release_cow_input_if_copied(a, result);
    return result;
}

// COW scalar broadcast F32: result[i] = v[i] OP scalar (in-place when v is unique)
blorp_Vector* blorp_simd_vector_scalar_op_f32_cow(int op, blorp_Vector* v, float scalar) {
    if (!v) return NULL;
    long len = v->capacity;
    int is_unique_v = blorp_is_unique(v);
    blorp_Vector* result;
    if (is_unique_v) {
        result = v;
    } else {
        result = blorp_vector_new_f32_like(v);
    }

    float* dv = (float*)v->data;
    float* dr = (float*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~3;
        __m128 vs = _mm_set1_ps(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_add_ps(_mm_loadu_ps(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_sub_ps(_mm_loadu_ps(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 4) {
                    _mm_storeu_ps(&dr[i], _mm_mul_ps(_mm_loadu_ps(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: {
                if (scalar == 0.0f) {
                    memset(dr, 0, len * sizeof(float));
                } else {
                    for (long i = 0; i < simd_len; i += 4) {
                        _mm_storeu_ps(&dr[i], _mm_div_ps(_mm_loadu_ps(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default: break;
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~3;
        float32x4_t vs = vdupq_n_f32(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vaddq_f32(vld1q_f32(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vsubq_f32(vld1q_f32(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 4) {
                    vst1q_f32(&dr[i], vmulq_f32(vld1q_f32(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: {
                if (scalar == 0.0f) {
                    memset(dr, 0, len * sizeof(float));
                } else {
                    for (long i = 0; i < simd_len; i += 4) {
                        vst1q_f32(&dr[i], vdivq_f32(vld1q_f32(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default: break;
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = dv[i] + scalar; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = dv[i] - scalar; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = dv[i] * scalar; break;
            case 3:
                if (scalar == 0.0f) { memset(dr, 0, len * sizeof(float)); }
                else { for (long i = 0; i < len; i++) dr[i] = dv[i] / scalar; }
                break;
            default: break;
        }
    #endif
    blorp_release_cow_input_if_copied(v, result);
    return result;
}

// COW scalar broadcast: result[i] = v[i] OP scalar (in-place when v is unique)
blorp_Vector* blorp_simd_vector_scalar_op_f64_cow(int op, blorp_Vector* v, double scalar) {
    if (!v) return NULL;
    long len = v->capacity;
    int is_unique_v = blorp_is_unique(v);
    blorp_Vector* result;
    if (is_unique_v) {
        result = v;
    } else {
        result = blorp_vector_new_like(v);
    }

    double* dv = (double*)v->data;
    double* dr = (double*)result->data;

    #if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        long simd_len = len & ~1;
        __m128d vs = _mm_set1_pd(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_add_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_sub_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    _mm_storeu_pd(&dr[i], _mm_mul_pd(_mm_loadu_pd(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: {
                if (scalar == 0.0) {
                    memset(dr, 0, len * sizeof(double));
                } else {
                    for (long i = 0; i < simd_len; i += 2) {
                        _mm_storeu_pd(&dr[i], _mm_div_pd(_mm_loadu_pd(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default: break;
        }
    #elif defined(BLORP_SIMD_NEON)
        long simd_len = len & ~1;
        float64x2_t vs = vdupq_n_f64(scalar);
        switch (op) {
            case 0:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vaddq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] + scalar;
                break;
            case 1:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vsubq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] - scalar;
                break;
            case 2:
                for (long i = 0; i < simd_len; i += 2) {
                    vst1q_f64(&dr[i], vmulq_f64(vld1q_f64(&dv[i]), vs));
                }
                for (long i = simd_len; i < len; i++) dr[i] = dv[i] * scalar;
                break;
            case 3: {
                if (scalar == 0.0) {
                    memset(dr, 0, len * sizeof(double));
                } else {
                    for (long i = 0; i < simd_len; i += 2) {
                        vst1q_f64(&dr[i], vdivq_f64(vld1q_f64(&dv[i]), vs));
                    }
                    for (long i = simd_len; i < len; i++) dr[i] = dv[i] / scalar;
                }
                break;
            }
            default: break;
        }
    #else
        switch (op) {
            case 0: for (long i = 0; i < len; i++) dr[i] = dv[i] + scalar; break;
            case 1: for (long i = 0; i < len; i++) dr[i] = dv[i] - scalar; break;
            case 2: for (long i = 0; i < len; i++) dr[i] = dv[i] * scalar; break;
            case 3:
                if (scalar == 0.0) { memset(dr, 0, len * sizeof(double)); }
                else { for (long i = 0; i < len; i++) dr[i] = dv[i] / scalar; }
                break;
            default: break;
        }
    #endif
    blorp_release_cow_input_if_copied(v, result);
    return result;
}

// ============================================================================
// ARC (Automatic Reference Counting) Runtime
// ============================================================================

// blorp_Object and blorp_Vector are forward-declared above for SIMD functions
typedef struct { blorp_Object header; long len; long capacity; char data[]; } blorp_String;
#define BLORP_LIST_STORAGE_POINTER 0
#define BLORP_LIST_STORAGE_INLINE 1
#define BLORP_LIST_CALLBACK_BITS 0
#define BLORP_LIST_CALLBACK_BOXED_STRUCT 1
#define BLORP_VECTOR_CALLBACK_BITS 0
#define BLORP_VECTOR_CALLBACK_BOXED_STRUCT 1
#define BLORP_VECTOR_CALLBACK_BOXED_FLOAT 2
#define BLORP_VECTOR_CALLBACK_BOXED_FLOAT32 3
typedef struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[5]; void* data[]; } blorp_List;
void* blorp_list_get(blorp_List* list, long index);

// Memory statistics — struct defined above (before SIMD section)

// Per-type leak accumulator
#define LEAK_TYPE_SLOTS 64
static struct { const char* tag; long count; size_t bytes; } __leak_type_table[LEAK_TYPE_SLOTS];

static void __leak_type_record(const char* tag, size_t bytes) {
    if (!tag) tag = "(unknown)";
    // Linear probe — small table, few types expected
    for (int i = 0; i < LEAK_TYPE_SLOTS; i++) {
        if (__leak_type_table[i].tag == NULL) {
            __leak_type_table[i].tag = tag;
            __leak_type_table[i].count = 1;
            __leak_type_table[i].bytes = bytes;
            return;
        }
        // Pointer comparison (tags are string literals)
        if (__leak_type_table[i].tag == tag ||
            strcmp(__leak_type_table[i].tag, tag) == 0) {
            __leak_type_table[i].count++;
            __leak_type_table[i].bytes += bytes;
            return;
        }
    }
}

static int __leak_type_cmp(const void* a, const void* b) {
    long ca = ((const struct { const char* tag; long count; size_t bytes; }*)a)->count;
    long cb = ((const struct { const char* tag; long count; size_t bytes; }*)b)->count;
    return (cb > ca) - (cb < ca);
}

static void __blorp_leak_report(void) {
    if (!__leak_tracking_enabled) return;
    long leaked = atomic_load(&global_mem_stats.current_objects);
    if (leaked < 0) leaked = 0;
    long bytes = atomic_load(&global_mem_stats.bytes_allocated);
    if (bytes < 0) bytes = 0;
    unsigned long current_epoch = atomic_load(&global_mem_stats.epoch);
    fprintf(stderr, "blorp: leak check: %ld allocs, %ld releases, %ld leaked, %ld bytes\n",
            (long)atomic_load(&global_mem_stats.total_allocations),
            (long)atomic_load(&global_mem_stats.total_releases),
            leaked, bytes);

    // Walk live-object list for per-type breakdown
    if (leaked > 0 && __leak_tracking_enabled) {
        memset(__leak_type_table, 0, sizeof(__leak_type_table));
        long counted = 0;
        pthread_mutex_lock(&__alloc_meta_mutex);
        blorp_AllocMeta* meta = __alloc_live_sentinel.live_next;
        while (meta && counted < 10000) {  // cap to prevent infinite walk
            blorp_Object* obj = meta->object;
            // Skip immortal singletons (None, True, False, etc.)
            long rc = (long)atomic_load(&obj->refcount);
            if (rc != LONG_MAX && meta->stats_tracked && meta->stats_epoch == current_epoch) {
                __leak_type_record(meta->type_tag, meta->alloc_size);
                counted++;
            }
            meta = meta->live_next;
        }
        pthread_mutex_unlock(&__alloc_meta_mutex);
        // Print per-type summary
        qsort(__leak_type_table, LEAK_TYPE_SLOTS,
              sizeof(__leak_type_table[0]), __leak_type_cmp);
        fprintf(stderr, "\nLeaked by type:\n");
        fprintf(stderr, "  %-20s %8s %10s\n", "TYPE", "COUNT", "BYTES");
        for (int i = 0; i < LEAK_TYPE_SLOTS && __leak_type_table[i].count > 0; i++) {
            fprintf(stderr, "  %-20s %8ld %10zu\n",
                    __leak_type_table[i].tag,
                    __leak_type_table[i].count,
                    __leak_type_table[i].bytes);
        }
    }
    // Strict mode: exit non-zero when leaks detected
    if (leaked > 0) {
        _exit(99);
    }
}

// Pool drain must run BEFORE leak report (atexit runs in reverse registration order)
static void __blorp_drain_pool_at_exit(void);
__attribute__((constructor))
static void __blorp_init_leak_report(void) {
    atexit(__blorp_leak_report);
    atexit(__blorp_drain_pool_at_exit);  // registered after, so runs before leak report
}

__attribute__((constructor))
static void __blorp_init_signal_handlers(void) {
    signal(SIGPIPE, SIG_IGN);
}

// ============================================================================
// Small-Object Pool — free-list allocator for objects <= 128 bytes
// Bypasses malloc/free for hot allocation paths (Options, small strings, records).
// Thread-local free lists, no locking. Overflow falls through to system allocator.
// ============================================================================
#define BLORP_POOL_MAX_SIZE 128
#define BLORP_POOL_CLASSES 4
#define BLORP_POOL_MAX_DEPTH 512

// Size classes: 32, 64, 96, 128
static const size_t blorp_pool_sizes[BLORP_POOL_CLASSES] = {32, 64, 96, 128};

// Thread-local free lists (head pointer + count per class)
static _Thread_local void* blorp_pool_free[BLORP_POOL_CLASSES] = {0};
static _Thread_local int blorp_pool_count[BLORP_POOL_CLASSES] = {0};

// Map allocation size to pool class index. Returns -1 if too large or zero.
static inline int blorp_pool_class(size_t size) {
    if (size == 0) return -1;   // SIMD objects have alloc_size=0 — must not pool
    if (size <= 32) return 0;
    if (size <= 64) return 1;
    if (size <= 96) return 2;
    if (size <= 128) return 3;
    return -1;
}

// Drain all pool free lists — called at exit for clean Valgrind/ASan reports.
// Validates next-pointers to prevent crashes from pool corruption: if a freed
// object's memory was overwritten (e.g., by an out-of-bounds write from a
// nearby allocation), the stored next-pointer may be invalid. We stop draining
// a class's list on the first suspicious pointer rather than crashing.
static void blorp_pool_drain(void) {
    for (int c = 0; c < BLORP_POOL_CLASSES; c++) {
        int safety = blorp_pool_count[c] + 16;  // upper bound + margin
        while (blorp_pool_free[c] && safety-- > 0) {
            void* obj = blorp_pool_free[c];
            void* next = *(void**)obj;
            // Validate: next must be NULL or pointer-aligned
            if (next != NULL && ((uintptr_t)next & 0x7) != 0) {
                blorp_pool_free[c] = NULL;  // stop: corrupted list
                break;
            }
            blorp_pool_free[c] = next;
            free(obj);
        }
        blorp_pool_free[c] = NULL;
        blorp_pool_count[c] = 0;
    }
}

static void __blorp_drain_pool_at_exit(void) { blorp_pool_drain(); }

void* blorp_alloc(size_t size) {
    void* obj;
    size_t actual_size = size;
    int cls = blorp_pool_class(size);

    // Try pool for small objects.
    // Pool is disabled under ASan — ASan tracks malloc/free precisely and the pool's
    // memory reuse bypasses that tracking, causing false heap-buffer-overflow reports.
// Pool disabled under ASan
#if !defined(BLORP_ASAN)
    if (cls >= 0 && blorp_pool_free[cls] != NULL) {
        // Pop from free list — reuse first 8 bytes as next pointer
        obj = blorp_pool_free[cls];
        blorp_pool_free[cls] = *(void**)obj;
        blorp_pool_count[cls]--;
        actual_size = blorp_pool_sizes[cls];
    } else
#endif
    {
        // Round up to class size for poolable objects (so free can recycle)
        if (cls >= 0) actual_size = blorp_pool_sizes[cls];
        obj = malloc(actual_size);
        if (!obj) {
            fprintf(stderr, "blorp: out of memory (requested %zu bytes)\n", size);
            exit(1);
        }
    }

    blorp_Object* header = (blorp_Object*)obj;
    blorp_init_object_header(
        header,
        cls >= 0 ? (uint32_t)cls : BLORP_ALLOC_CLASS_DIRECT,
        actual_size
    );
    return obj;
}

static void blorp_untrack_allocated_object(void* obj) {
    if (!obj) return;
    blorp_Object* header = (blorp_Object*)obj;
    blorp_AllocMeta* meta = __alloc_meta_take(header);
    if (!meta) return;
    bool counted_in_current_epoch =
        meta->stats_tracked && meta->stats_epoch == atomic_load(&global_mem_stats.epoch);
    if (__blorp_stats_enabled && counted_in_current_epoch) {
        global_mem_stats.total_allocations--;
        global_mem_stats.current_objects--;
        global_mem_stats.bytes_allocated -= (long)meta->alloc_size;
    }
    free(meta);
}

static void* blorp_alloc_untracked(size_t size) {
    void* obj = blorp_alloc(size);
    blorp_untrack_allocated_object(obj);
    return obj;
}

// Tagged allocation: sets type_tag for leak reporting.
// type_tag is a string literal pointer — no allocation or copy needed.
void blorp_set_type_tag(void* obj, const char* tag) {
    if (obj) __alloc_meta_set_type_tag((blorp_Object*)obj, tag);
}

// Convenience: allocate and tag in one call (used by runtime internals)
static inline void* blorp_alloc_tagged(size_t size, const char* tag) {
    void* obj = blorp_alloc(size);
    blorp_set_type_tag(obj, tag);
    return obj;
}

// Macro for tagging after allocation — less invasive than changing every call site.
// Usage: BLORP_TAG(ptr, "String")
#define BLORP_TAG(ptr, tag) blorp_set_type_tag((void*)(ptr), (tag))

static void blorp_io_waiter_wake_all(blorp_IoWaiterList* waiters);
static void blorp_io_deadline_queue_insert(
    blorp_IoWaiter* waiter,
    blorp_TcpInner* owner
);
static void blorp_io_deadline_queue_remove(blorp_IoWaiter* waiter);
static long blorp_io_deadline_queue_count(void);
static uint64_t blorp_io_deadline_queue_drain(void);
static void blorp_io_deadline_queue_clear(void);
static int blorp_io_reactor_unregister_inner(int fd, uint64_t generation);
static inline int __blorp_is_cancelled(void);
static int __blorp_cancel_current_task_if_requested(void);
static int blorp_io_reactor_wait_ready(
    int fd,
    uint64_t generation,
    int interest,
    long timeout_ms
);
static int blorp_io_reactor_take_ready(
    int fd,
    uint64_t generation,
    int interests
);

typedef void (*blorp_CancelCleanupFn)(void*);

typedef struct blorp_CancelCleanupFrame {
    struct blorp_CancelCleanupFrame* prev;
    const void* slot;
    void* value;
    blorp_CancelCleanupFn release_value;
    bool active;
} blorp_CancelCleanupFrame;

void __blorp_task_cleanup_push_slow(blorp_CancelCleanupFrame* frame,
                                    const void* slot, void* value,
                                    blorp_CancelCleanupFn release_value);
void __blorp_task_cleanup_pop_slot_slow(const void* slot);

static blorp_IoWakeReason blorp_tcp_inner_park_current_fiber(
    blorp_TcpInner* inner,
    blorp_IoWaitKind kind,
    int fd,
    uint64_t generation,
    int interest,
    long timeout_ms
);

static void blorp_io_waiter_init(
    blorp_IoWaiter* waiter,
    blorp_IoWaitKind kind,
    struct blorp_Fiber* fiber,
    uint64_t generation,
    uint64_t deadline_ns
) {
    if (!waiter) return;
    atomic_init(&waiter->refcount, 1);
    waiter->kind = kind;
    waiter->wake_reason = BLORP_IO_WAKE_NONE;
    waiter->fiber = fiber;
    waiter->generation = generation;
    waiter->deadline_ns = deadline_ns;
    waiter->deadline_index = -1;
    waiter->cancelled = false;
    waiter->installed = false;
    waiter->deadline_queued = false;
    waiter->owner = NULL;
    waiter->deadline_owner = NULL;
    waiter->next = NULL;
}

static blorp_IoWaiter* blorp_io_waiter_new(
    blorp_IoWaitKind kind,
    struct blorp_Fiber* fiber,
    uint64_t generation,
    uint64_t deadline_ns
) {
    blorp_IoWaiter* waiter =
        (blorp_IoWaiter*)blorp_malloc_checked(sizeof(blorp_IoWaiter));
    blorp_io_waiter_init(waiter, kind, fiber, generation, deadline_ns);
    return waiter;
}

static void blorp_io_waiter_retain(blorp_IoWaiter* waiter) {
    if (!waiter) return;
    atomic_fetch_add_explicit(&waiter->refcount, 1, memory_order_relaxed);
}

static void blorp_io_waiter_release(blorp_IoWaiter* waiter) {
    if (!waiter) return;
    long old_refcount =
        atomic_fetch_sub_explicit(&waiter->refcount, 1, memory_order_acq_rel);
    if (old_refcount > 1) return;
    if (waiter->installed || waiter->deadline_queued || waiter->deadline_owner) {
        fprintf(stderr, "blorp: IO waiter released while still owned (bug)\n");
        abort();
    }
    free(waiter);
}

static blorp_IoWaiterList blorp_io_waiter_list_empty(void) {
    return (blorp_IoWaiterList){ .head = NULL, .tail = NULL };
}

static void blorp_io_waiter_list_push(
    blorp_IoWaiterList* list,
    blorp_IoWaiter* waiter
) {
    if (!list || !waiter) return;
    waiter->next = NULL;
    if (list->tail) {
        list->tail->next = waiter;
    } else {
        list->head = waiter;
    }
    list->tail = waiter;
}

static void blorp_io_waiter_list_append(
    blorp_IoWaiterList* list,
    blorp_IoWaiterList* extra
) {
    if (!list || !extra || !extra->head) return;
    if (list->tail) {
        list->tail->next = extra->head;
    } else {
        list->head = extra->head;
    }
    list->tail = extra->tail;
    extra->head = NULL;
    extra->tail = NULL;
}

static long blorp_io_waiter_list_count(const blorp_IoWaiterList* list) {
    long count = 0;
    if (!list) return 0;
    for (blorp_IoWaiter* waiter = list->head; waiter; waiter = waiter->next) {
        count++;
    }
    return count;
}

static blorp_IoWaiter** blorp_tcp_inner_waiter_slot(
    blorp_TcpInner* inner,
    blorp_IoWaitKind kind
) {
    if (!inner) return NULL;
    switch (kind) {
        case BLORP_IO_WAIT_ACCEPT:
            return inner->kind == BLORP_TCP_HANDLE_LISTENER ? &inner->accept_waiter
                                                            : NULL;
        case BLORP_IO_WAIT_CONNECT:
            return inner->kind == BLORP_TCP_HANDLE_STREAM ? &inner->connect_waiter
                                                          : NULL;
        case BLORP_IO_WAIT_READ:
            return inner->kind == BLORP_TCP_HANDLE_STREAM ? &inner->read_waiter
                                                          : NULL;
        case BLORP_IO_WAIT_WRITE:
            return inner->kind == BLORP_TCP_HANDLE_STREAM ? &inner->write_waiter
                                                          : NULL;
        case BLORP_IO_WAIT_NONE:
        default:
            return NULL;
    }
}

static int blorp_tcp_inner_install_waiter(
    blorp_TcpInner* inner,
    blorp_IoWaiter* waiter
) {
    if (!inner || !waiter || waiter->installed ||
        waiter->wake_reason != BLORP_IO_WAKE_NONE) {
        return -1;
    }

    pthread_mutex_lock(&inner->mutex);
    blorp_IoWaiter** slot = blorp_tcp_inner_waiter_slot(inner, waiter->kind);
    if (!slot || *slot || inner->state != BLORP_TCP_STATE_OPEN || inner->fd < 0 ||
        waiter->generation != inner->generation) {
        pthread_mutex_unlock(&inner->mutex);
        return -1;
    }
    *slot = waiter;
    waiter->installed = true;
    waiter->owner = inner;
    waiter->next = NULL;
    pthread_mutex_unlock(&inner->mutex);
    return 0;
}

static int blorp_tcp_inner_remove_waiter(
    blorp_TcpInner* inner,
    blorp_IoWaiter* waiter
) {
    if (!inner || !waiter) return 0;
    pthread_mutex_lock(&inner->mutex);
    blorp_IoWaiter** slot = blorp_tcp_inner_waiter_slot(inner, waiter->kind);
    if (!slot || *slot != waiter) {
        pthread_mutex_unlock(&inner->mutex);
        return 0;
    }
    *slot = NULL;
    waiter->installed = false;
    waiter->owner = NULL;
    waiter->next = NULL;
    pthread_mutex_unlock(&inner->mutex);
    blorp_io_deadline_queue_remove(waiter);
    return 1;
}

static void blorp_tcp_inner_extract_waiter_slot_locked(
    blorp_IoWaiter** slot,
    blorp_IoWakeReason reason,
    blorp_IoWaiterList* waiters
);

static blorp_IoWaiterList blorp_tcp_inner_extract_waiter(
    blorp_TcpInner* inner,
    blorp_IoWaitKind kind,
    uint64_t generation,
    blorp_IoWakeReason reason
) {
    blorp_IoWaiterList waiters = blorp_io_waiter_list_empty();
    if (!inner || reason == BLORP_IO_WAKE_NONE) return waiters;
    pthread_mutex_lock(&inner->mutex);
    blorp_IoWaiter** slot = blorp_tcp_inner_waiter_slot(inner, kind);
    if (slot && *slot && inner->generation == generation &&
        (*slot)->generation == generation) {
        blorp_tcp_inner_extract_waiter_slot_locked(slot, reason, &waiters);
    }
    pthread_mutex_unlock(&inner->mutex);
    return waiters;
}

static int blorp_tcp_inner_cancel_waiter(
    blorp_TcpInner* inner,
    blorp_IoWaiter* waiter
) {
    if (!inner || !waiter) return 0;
    blorp_IoWaiterList waiters = blorp_io_waiter_list_empty();
    pthread_mutex_lock(&inner->mutex);
    blorp_IoWaiter** slot = blorp_tcp_inner_waiter_slot(inner, waiter->kind);
    if (slot && *slot == waiter) {
        blorp_tcp_inner_extract_waiter_slot_locked(
            slot, BLORP_IO_WAKE_CANCELLED, &waiters);
    }
    pthread_mutex_unlock(&inner->mutex);
    int cancelled = waiters.head != NULL;
    blorp_io_waiter_wake_all(&waiters);
    return cancelled;
}

static void blorp_tcp_inner_extract_waiter_slot_locked(
    blorp_IoWaiter** slot,
    blorp_IoWakeReason reason,
    blorp_IoWaiterList* waiters
) {
    if (!slot || !*slot) return;
    blorp_IoWaiter* waiter = *slot;
    *slot = NULL;
    waiter->installed = false;
    waiter->owner = NULL;
    waiter->wake_reason = reason;
    if (reason == BLORP_IO_WAKE_CANCELLED) waiter->cancelled = true;
    blorp_io_deadline_queue_remove(waiter);
    blorp_io_waiter_list_push(waiters, waiter);
}

static blorp_IoWaiterList blorp_tcp_inner_extract_waiters_locked(
    blorp_TcpInner* inner,
    blorp_IoWakeReason reason
) {
    blorp_IoWaiterList waiters = blorp_io_waiter_list_empty();
    if (!inner) return waiters;
    blorp_tcp_inner_extract_waiter_slot_locked(
        &inner->accept_waiter, reason, &waiters);
    blorp_tcp_inner_extract_waiter_slot_locked(
        &inner->connect_waiter, reason, &waiters);
    blorp_tcp_inner_extract_waiter_slot_locked(
        &inner->read_waiter, reason, &waiters);
    blorp_tcp_inner_extract_waiter_slot_locked(
        &inner->write_waiter, reason, &waiters);
    return waiters;
}

static blorp_IoWaiterList blorp_tcp_inner_close_and_extract_waiters(
    blorp_TcpInner* inner,
    blorp_IoWakeReason reason,
    int* closed_fd_out,
    uint64_t* closed_generation_out
) {
    blorp_IoWaiterList waiters = blorp_io_waiter_list_empty();
    if (closed_fd_out) *closed_fd_out = -1;
    if (closed_generation_out) *closed_generation_out = 0;
    if (!inner) return waiters;
    pthread_mutex_lock(&inner->mutex);
    if (inner->state != BLORP_TCP_STATE_CLOSED) {
        inner->state = BLORP_TCP_STATE_CLOSED;
        if (inner->fd >= 0) {
            if (closed_fd_out) *closed_fd_out = inner->fd;
            if (closed_generation_out) *closed_generation_out = inner->generation;
            close(inner->fd);
            inner->fd = -1;
        }
    }
    waiters = blorp_tcp_inner_extract_waiters_locked(inner, reason);
    pthread_mutex_unlock(&inner->mutex);
    return waiters;
}

static blorp_TcpInner* blorp_tcp_inner_new(blorp_TcpHandleKind kind, int fd) {
    blorp_TcpInner* inner = (blorp_TcpInner*)calloc(1, sizeof(blorp_TcpInner));
    if (!inner) {
        fprintf(stderr, "blorp: out of memory (requested %zu bytes)\n",
                sizeof(blorp_TcpInner));
        exit(1);
    }
    atomic_init(&inner->refcount, 1);
    inner->fd = fd;
    inner->generation =
        atomic_fetch_add_explicit(&blorp_tcp_next_generation, 1, memory_order_relaxed);
    inner->kind = kind;
    inner->state = BLORP_TCP_STATE_OPEN;
    inner->default_timeout_ms = -1;
    if (pthread_mutex_init(&inner->mutex, NULL) != 0) {
        close(inner->fd);
        free(inner);
        fprintf(stderr, "blorp: failed to initialize TCP handle mutex\n");
        exit(1);
    }
    return inner;
}

static void blorp_tcp_inner_retain(blorp_TcpInner* inner) {
    if (inner) {
        atomic_fetch_add_explicit(&inner->refcount, 1, memory_order_relaxed);
    }
}

static void blorp_tcp_inner_release(blorp_TcpInner* inner) {
    if (!inner) return;
    long old_refcount =
        atomic_fetch_sub_explicit(&inner->refcount, 1, memory_order_acq_rel);
    if (old_refcount > 1) return;

    blorp_IoWaiterList waiters =
        blorp_tcp_inner_close_and_extract_waiters(
            inner, BLORP_IO_WAKE_CLOSED, NULL, NULL);
    if (waiters.head) {
        fprintf(stderr, "blorp: TCP handle destroyed with waiting fiber (bug)\n");
    }
    blorp_io_waiter_wake_all(&waiters);
    pthread_mutex_destroy(&inner->mutex);
    free(inner);
}

static long blorp_tcp_inner_fd(blorp_TcpInner* inner) {
    if (!inner) return -1;
    pthread_mutex_lock(&inner->mutex);
    long fd = inner->fd;
    pthread_mutex_unlock(&inner->mutex);
    return fd;
}

static int blorp_tcp_inner_begin_op(blorp_TcpInner* inner, long* fd_out) {
    if (!inner || !fd_out) return -1;
    pthread_mutex_lock(&inner->mutex);
    if (inner->state != BLORP_TCP_STATE_OPEN || inner->fd < 0) {
        pthread_mutex_unlock(&inner->mutex);
        return -1;
    }
    *fd_out = inner->fd;
    return 0;
}

static void blorp_tcp_inner_end_op(blorp_TcpInner* inner) {
    if (inner) pthread_mutex_unlock(&inner->mutex);
}

static int blorp_tcp_inner_begin_write_op(blorp_TcpInner* inner) {
    if (!inner) return -1;
    pthread_mutex_lock(&inner->mutex);
    if (inner->state != BLORP_TCP_STATE_OPEN || inner->fd < 0) {
        pthread_mutex_unlock(&inner->mutex);
        return -1;
    }
    if (inner->write_active) {
        pthread_mutex_unlock(&inner->mutex);
        return -2;
    }
    inner->write_active = true;
    blorp_tcp_inner_retain(inner);
    pthread_mutex_unlock(&inner->mutex);
    return 0;
}

static void blorp_tcp_inner_end_write_op(blorp_TcpInner* inner) {
    if (!inner) return;
    pthread_mutex_lock(&inner->mutex);
    inner->write_active = false;
    pthread_mutex_unlock(&inner->mutex);
    blorp_tcp_inner_release(inner);
}

static void blorp_tcp_inner_close(blorp_TcpInner* inner) {
    if (!inner) return;
    int closed_fd = -1;
    uint64_t closed_generation = 0;
    blorp_IoWaiterList waiters =
        blorp_tcp_inner_close_and_extract_waiters(
            inner, BLORP_IO_WAKE_CLOSED, &closed_fd, &closed_generation);
    if (closed_fd >= 0 && blorp_io_reactor_is_started()) {
        (void)blorp_io_reactor_unregister_inner(closed_fd, closed_generation);
    }
    blorp_io_waiter_wake_all(&waiters);
}

static void blorp_tcp_listener_destructor(void* obj) {
    blorp_TcpListener* listener = (blorp_TcpListener*)obj;
    blorp_tcp_inner_release(listener->inner);
    listener->inner = NULL;
}

static void blorp_tcp_stream_destructor(void* obj) {
    blorp_TcpStream* stream = (blorp_TcpStream*)obj;
    blorp_tcp_inner_release(stream->inner);
    stream->inner = NULL;
}

static bool blorp_tcp_fd_arg_is_valid(long fd) {
    return fd >= 0 && fd <= INT_MAX;
}

static bool blorp_tcp_fd_is_stream_socket(int raw_fd) {
    int socket_type = 0;
    socklen_t socket_type_len = sizeof(socket_type);
    return getsockopt(
               raw_fd, SOL_SOCKET, SO_TYPE, &socket_type, &socket_type_len) == 0 &&
           socket_type == SOCK_STREAM;
}

static bool blorp_tcp_fd_is_listening_stream_socket(int raw_fd) {
    if (!blorp_tcp_fd_is_stream_socket(raw_fd)) return false;
#if defined(SO_ACCEPTCONN)
    int accept_conn = 0;
    socklen_t accept_conn_len = sizeof(accept_conn);
    if (getsockopt(
            raw_fd, SOL_SOCKET, SO_ACCEPTCONN, &accept_conn,
            &accept_conn_len) != 0) {
        return errno == ENOPROTOOPT || errno == EINVAL;
    }
    return accept_conn != 0;
#else
    return true;
#endif
}

static bool blorp_tcp_fd_arg_to_open_socket_fd(
    long fd,
    int* raw_fd_out,
    bool require_listener
) {
    if (!raw_fd_out || !blorp_tcp_fd_arg_is_valid(fd)) return false;
    int raw_fd = (int)fd;
    if (blorp_runtime_set_cloexec(raw_fd) != 0) return false;
    if (require_listener) {
        if (!blorp_tcp_fd_is_listening_stream_socket(raw_fd)) return false;
    } else if (!blorp_tcp_fd_is_stream_socket(raw_fd)) {
        return false;
    }
    if (blorp_io_reactor_set_nonblocking(raw_fd) != 0) return false;
    *raw_fd_out = raw_fd;
    return true;
}

static blorp_TcpListener* blorp_tcp_listener_from_open_fd(int raw_fd) {
    blorp_TcpInner* inner =
        blorp_tcp_inner_new(BLORP_TCP_HANDLE_LISTENER, raw_fd);
    blorp_TcpListener* listener =
        (blorp_TcpListener*)blorp_alloc(sizeof(blorp_TcpListener));
    BLORP_TAG(listener, "TcpListener");
    BLORP_SET_DESTRUCTOR(listener, blorp_tcp_listener_destructor);
    listener->inner = inner;
    return listener;
}

static blorp_TcpStream* blorp_tcp_stream_from_open_fd(int raw_fd) {
    blorp_tcp_suppress_sigpipe(raw_fd);
    blorp_TcpInner* inner =
        blorp_tcp_inner_new(BLORP_TCP_HANDLE_STREAM, raw_fd);
    blorp_TcpStream* stream = (blorp_TcpStream*)blorp_alloc(sizeof(blorp_TcpStream));
    BLORP_TAG(stream, "TcpStream");
    BLORP_SET_DESTRUCTOR(stream, blorp_tcp_stream_destructor);
    stream->inner = inner;
    return stream;
}

blorp_TcpListener* blorp_tcp_listener_from_fd(long fd) {
    int raw_fd;
    if (!blorp_tcp_fd_arg_to_open_socket_fd(fd, &raw_fd, true)) return NULL;
    return blorp_tcp_listener_from_open_fd(raw_fd);
}

blorp_TcpStream* blorp_tcp_stream_from_fd(long fd) {
    int raw_fd;
    if (!blorp_tcp_fd_arg_to_open_socket_fd(fd, &raw_fd, false)) return NULL;
    return blorp_tcp_stream_from_open_fd(raw_fd);
}

long blorp_tcp_listener_fd(blorp_TcpListener* listener) {
    return listener ? blorp_tcp_inner_fd(listener->inner) : -1;
}

long blorp_tcp_stream_fd(blorp_TcpStream* stream) {
    return stream ? blorp_tcp_inner_fd(stream->inner) : -1;
}

static int blorp_io_reactor_set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return 0;
}

static int blorp_runtime_set_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) return -1;
    return 0;
}

static int blorp_runtime_socket_cloexec(int domain, int type, int protocol) {
#if defined(SOCK_CLOEXEC)
    int fd = socket(domain, type | SOCK_CLOEXEC, protocol);
    if (fd >= 0) return fd;
    if (errno != EINVAL) return -1;
#endif
    int fd = socket(domain, type, protocol);
    if (fd < 0) return -1;
    if (blorp_runtime_set_cloexec(fd) != 0) {
        int saved_errno = errno;
        close(fd);
        errno = saved_errno;
        return -1;
    }
    return fd;
}

static int blorp_runtime_accept_cloexec(
    int fd,
    struct sockaddr* addr,
    socklen_t* addr_len
) {
#if defined(__linux__) && defined(SOCK_CLOEXEC)
    int client_fd = accept4(fd, addr, addr_len, SOCK_CLOEXEC);
    if (client_fd >= 0) return client_fd;
    if (errno != ENOSYS && errno != EINVAL) return -1;
#endif
    int client_fd = accept(fd, addr, addr_len);
    if (client_fd < 0) return -1;
    if (blorp_runtime_set_cloexec(client_fd) != 0) {
        int saved_errno = errno;
        close(client_fd);
        errno = saved_errno;
        return -1;
    }
    return client_fd;
}

static int blorp_runtime_pipe_cloexec_nonblock(int fds[2]) {
    if (!fds) {
        errno = EINVAL;
        return -1;
    }
#if defined(__linux__) && defined(O_CLOEXEC) && defined(O_NONBLOCK)
    if (pipe2(fds, O_CLOEXEC | O_NONBLOCK) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL) return -1;
#endif
    fds[0] = -1;
    fds[1] = -1;
    if (pipe(fds) != 0) return -1;
    if (blorp_runtime_set_cloexec(fds[0]) != 0 ||
        blorp_runtime_set_cloexec(fds[1]) != 0 ||
        blorp_io_reactor_set_nonblocking(fds[0]) != 0 ||
        blorp_io_reactor_set_nonblocking(fds[1]) != 0) {
        int saved_errno = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = -1;
        fds[1] = -1;
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static void blorp_io_reactor_wake_control(void) {
    if (__blorp_io_reactor.control_write_fd < 0) return;
    unsigned char byte = 1;
    while (write(__blorp_io_reactor.control_write_fd, &byte, 1) < 0) {
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        return;
    }
    __blorp_scheduler_stat_inc(&global_scheduler_stats.reactor_control_wakes);
}

static void blorp_io_reactor_drain_control(void) {
    if (__blorp_io_reactor.control_read_fd < 0) return;
    unsigned char buf[64];
    while (read(__blorp_io_reactor.control_read_fd, buf, sizeof(buf)) > 0) {
    }
}

static blorp_IoBackendKind blorp_io_reactor_active_backend(void) {
    // Phase 2 starts with the portable level-triggered poll loop. Native
    // kqueue/epoll backends should not be reported active until their loops
    // are implemented and tested.
    return BLORP_IO_BACKEND_POLL;
}

static blorp_IoRegistration* blorp_io_reactor_find_locked(
    int fd,
    uint64_t generation
) {
    blorp_IoRegistration* reg = __blorp_io_reactor.registrations;
    while (reg) {
        if (reg->fd == fd && reg->generation == generation) return reg;
        reg = reg->next;
    }
    return NULL;
}

static size_t blorp_io_reactor_registration_count_locked(void) {
    size_t count = 0;
    for (blorp_IoRegistration* reg = __blorp_io_reactor.registrations; reg;
         reg = reg->next) {
        count++;
    }
    return count;
}

static blorp_IoRegistrationSnapshot* blorp_io_reactor_snapshot_locked(
    size_t* out_count
) {
    size_t count = blorp_io_reactor_registration_count_locked();
    *out_count = count;
    if (count == 0) return NULL;
    blorp_IoRegistrationSnapshot* snapshots =
        (blorp_IoRegistrationSnapshot*)blorp_malloc_checked(
            count * sizeof(blorp_IoRegistrationSnapshot));
    size_t i = 0;
    for (blorp_IoRegistration* reg = __blorp_io_reactor.registrations; reg;
         reg = reg->next) {
        snapshots[i].fd = reg->fd;
        snapshots[i].generation = reg->generation;
        snapshots[i].interests = reg->interests;
        i++;
    }
    return snapshots;
}

static short blorp_io_reactor_poll_events(int interests) {
    short events = 0;
    if (interests & BLORP_IO_INTEREST_READ) events |= POLLIN;
    if (interests & BLORP_IO_INTEREST_WRITE) events |= POLLOUT;
    return events;
}

static int blorp_io_reactor_ready_events(short revents) {
    int ready = 0;
    if (revents & (POLLIN | POLLHUP | POLLERR)) ready |= BLORP_IO_INTEREST_READ;
    if (revents & (POLLOUT | POLLHUP | POLLERR)) ready |= BLORP_IO_INTEREST_WRITE;
    return ready;
}

static void blorp_io_reactor_mark_ready(
    int fd,
    uint64_t generation,
    int ready_events
) {
    blorp_IoWaiterList waiters = blorp_io_waiter_list_empty();
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* reg =
        blorp_io_reactor_find_locked(fd, generation);
    if (reg) {
        int current_ready = ready_events & reg->interests;
        if (current_ready != 0) {
            reg->ready_events |= current_ready;
            long ready_count = 0;
            if (current_ready & BLORP_IO_INTEREST_READ) ready_count++;
            if (current_ready & BLORP_IO_INTEREST_WRITE) ready_count++;
            __blorp_scheduler_stat_add(
                &global_scheduler_stats.reactor_ready_events, ready_count);
            // Registrations model one pending operation, not a permanent
            // subscription. Suppress repeated level-triggered notifications
            // until the operation retries and explicitly re-registers.
            reg->interests &= ~current_ready;
            if (reg->inner) {
                if (current_ready & BLORP_IO_INTEREST_READ) {
                    blorp_IoWaiterList read_waiters =
                        reg->inner->kind == BLORP_TCP_HANDLE_LISTENER
                            ? blorp_tcp_inner_extract_waiter(
                                  reg->inner, BLORP_IO_WAIT_ACCEPT,
                                  generation, BLORP_IO_WAKE_READY)
                            : blorp_tcp_inner_extract_waiter(
                                  reg->inner, BLORP_IO_WAIT_READ,
                                  generation, BLORP_IO_WAKE_READY);
                    blorp_io_waiter_list_append(&waiters, &read_waiters);
                }
                if (current_ready & BLORP_IO_INTEREST_WRITE) {
                    blorp_IoWaiterList connect_waiters =
                        blorp_tcp_inner_extract_waiter(
                            reg->inner, BLORP_IO_WAIT_CONNECT,
                            generation, BLORP_IO_WAKE_READY);
                    blorp_IoWaiterList write_waiters =
                        blorp_tcp_inner_extract_waiter(
                            reg->inner, BLORP_IO_WAIT_WRITE,
                            generation, BLORP_IO_WAKE_READY);
                    blorp_io_waiter_list_append(&waiters, &connect_waiters);
                    blorp_io_waiter_list_append(&waiters, &write_waiters);
                }
            }
            pthread_cond_broadcast(&__blorp_io_reactor.ready_cond);
        }
    }
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    __blorp_scheduler_stat_add(
        &global_scheduler_stats.reactor_waiter_wakes,
        blorp_io_waiter_list_count(&waiters));
    blorp_io_waiter_wake_all(&waiters);
}

static void* blorp_io_reactor_thread(void* arg) {
    (void)arg;
    while (true) {
        pthread_mutex_lock(&__blorp_io_reactor.mutex);
        if (__blorp_io_reactor.shutdown) {
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            return NULL;
        }
        size_t reg_count = 0;
        blorp_IoRegistrationSnapshot* snapshots =
            blorp_io_reactor_snapshot_locked(&reg_count);
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);

        size_t poll_count = reg_count + 1;
        struct pollfd* fds =
            (struct pollfd*)blorp_malloc_checked(poll_count * sizeof(struct pollfd));
        fds[0].fd = __blorp_io_reactor.control_read_fd;
        fds[0].events = POLLIN;
        fds[0].revents = 0;
        for (size_t i = 0; i < reg_count; i++) {
            fds[i + 1].fd = snapshots[i].fd;
            fds[i + 1].events =
                blorp_io_reactor_poll_events(snapshots[i].interests);
            fds[i + 1].revents = 0;
        }

        int rc;
        do {
            rc = poll(fds, (nfds_t)poll_count, -1);
        } while (rc < 0 && errno == EINTR);

        if (rc > 0) {
            __blorp_scheduler_stat_inc(&global_scheduler_stats.reactor_poll_wakes);
            if (fds[0].revents & POLLIN) {
                blorp_io_reactor_drain_control();
            }
            for (size_t i = 0; i < reg_count; i++) {
                short revents = fds[i + 1].revents;
                int ready = blorp_io_reactor_ready_events(revents);
                if (ready != 0) {
                    blorp_io_reactor_mark_ready(
                        snapshots[i].fd, snapshots[i].generation, ready);
                }
            }
        }

        free(fds);
        free(snapshots);
    }
}

void blorp_io_reactor_shutdown(void) {
    if (!blorp_io_reactor_is_started()) return;

    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    bool had_thread = __blorp_io_reactor.thread_started;
    __blorp_io_reactor.shutdown = true;
    pthread_cond_broadcast(&__blorp_io_reactor.ready_cond);
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    blorp_io_reactor_wake_control();

    if (had_thread) {
        pthread_join(__blorp_io_reactor.thread, NULL);
    }

    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* reg = __blorp_io_reactor.registrations;
    __blorp_io_reactor.registrations = NULL;
    while (reg) {
        blorp_IoRegistration* next = reg->next;
        if (reg->inner) blorp_tcp_inner_release(reg->inner);
        free(reg);
        reg = next;
    }
    if (__blorp_io_reactor.control_read_fd >= 0) {
        close(__blorp_io_reactor.control_read_fd);
        __blorp_io_reactor.control_read_fd = -1;
    }
    if (__blorp_io_reactor.control_write_fd >= 0) {
        close(__blorp_io_reactor.control_write_fd);
        __blorp_io_reactor.control_write_fd = -1;
    }
    __blorp_io_reactor.thread_started = false;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
}

static void blorp_io_reactor_init_once(void) {
    __blorp_io_reactor.backend = blorp_io_reactor_active_backend();
    __blorp_io_reactor.control_read_fd = -1;
    __blorp_io_reactor.control_write_fd = -1;
    int pthread_rc = pthread_mutex_init(&__blorp_io_reactor.mutex, NULL);
    if (pthread_rc != 0) {
        __blorp_io_reactor_init_error = pthread_rc;
        return;
    }
    pthread_rc = pthread_cond_init(&__blorp_io_reactor.ready_cond, NULL);
    if (pthread_rc != 0) {
        __blorp_io_reactor_init_error = pthread_rc;
        pthread_mutex_destroy(&__blorp_io_reactor.mutex);
        return;
    }
    int control_fds[2];
    if (blorp_runtime_pipe_cloexec_nonblock(control_fds) != 0) {
        __blorp_io_reactor_init_error = errno;
        pthread_cond_destroy(&__blorp_io_reactor.ready_cond);
        pthread_mutex_destroy(&__blorp_io_reactor.mutex);
        return;
    }
    __blorp_io_reactor.control_read_fd = control_fds[0];
    __blorp_io_reactor.control_write_fd = control_fds[1];
    blorp_io_reactor_set_started(true);
    pthread_rc =
        pthread_create(
            &__blorp_io_reactor.thread, NULL, blorp_io_reactor_thread, NULL);
    if (pthread_rc != 0) {
        __blorp_io_reactor_init_error = pthread_rc;
        blorp_io_reactor_set_started(false);
        close(control_fds[0]);
        close(control_fds[1]);
        pthread_cond_destroy(&__blorp_io_reactor.ready_cond);
        pthread_mutex_destroy(&__blorp_io_reactor.mutex);
        __blorp_io_reactor.control_read_fd = -1;
        __blorp_io_reactor.control_write_fd = -1;
        return;
    }
    __blorp_io_reactor.thread_started = true;
    atexit(blorp_io_reactor_shutdown);
}

int blorp_io_reactor_start(void) {
    pthread_once(&__blorp_io_reactor_once, blorp_io_reactor_init_once);
    return __blorp_io_reactor_init_error == 0 ? 0 : -1;
}

static int blorp_io_reactor_register_inner(
    blorp_TcpInner* inner,
    int fd,
    uint64_t generation,
    int interests
) {
    if (!inner || fd < 0 || interests == 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;

    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    pthread_mutex_lock(&inner->mutex);
    if (inner->state != BLORP_TCP_STATE_OPEN || inner->fd != fd ||
        inner->generation != generation) {
        pthread_mutex_unlock(&inner->mutex);
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);
        return -1;
    }
    blorp_IoRegistration* existing =
        blorp_io_reactor_find_locked(fd, generation);
    if (existing) {
        existing->interests |= interests;
        existing->ready_events &= existing->interests;
        pthread_mutex_unlock(&inner->mutex);
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);
        blorp_io_reactor_wake_control();
        return 0;
    }

    blorp_IoRegistration* reg =
        (blorp_IoRegistration*)blorp_malloc_checked(sizeof(blorp_IoRegistration));
    reg->fd = fd;
    reg->generation = generation;
    reg->interests = interests;
    reg->ready_events = 0;
    reg->inner = inner;
    blorp_tcp_inner_retain(inner);
    reg->next = __blorp_io_reactor.registrations;
    __blorp_io_reactor.registrations = reg;
    pthread_mutex_unlock(&inner->mutex);
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    blorp_io_reactor_wake_control();
    return 0;
}

static int blorp_io_reactor_register_fd_for_smoke(
    int fd,
    uint64_t generation,
    int interests
) {
    if (fd < 0 || interests == 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* existing =
        blorp_io_reactor_find_locked(fd, generation);
    if (existing) {
        existing->interests |= interests;
        existing->ready_events &= existing->interests;
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);
        blorp_io_reactor_wake_control();
        return 0;
    }
    blorp_IoRegistration* reg =
        (blorp_IoRegistration*)blorp_malloc_checked(sizeof(blorp_IoRegistration));
    reg->fd = fd;
    reg->generation = generation;
    reg->interests = interests;
    reg->ready_events = 0;
    reg->inner = NULL;
    reg->next = __blorp_io_reactor.registrations;
    __blorp_io_reactor.registrations = reg;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    blorp_io_reactor_wake_control();
    return 0;
}

static int blorp_io_reactor_update_interest(
    int fd,
    uint64_t generation,
    int interests
) {
    if (fd < 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* reg =
        blorp_io_reactor_find_locked(fd, generation);
    if (!reg) {
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);
        return -1;
    }
    reg->interests = interests;
    reg->ready_events &= interests;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    blorp_io_reactor_wake_control();
    return 0;
}

static int blorp_io_reactor_unregister_inner(int fd, uint64_t generation) {
    if (fd < 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration** link = &__blorp_io_reactor.registrations;
    while (*link) {
        blorp_IoRegistration* reg = *link;
        if (reg->fd == fd && reg->generation == generation) {
            *link = reg->next;
            if (reg->inner) blorp_tcp_inner_release(reg->inner);
            free(reg);
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            blorp_io_reactor_wake_control();
            return 0;
        }
        link = &reg->next;
    }
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    return -1;
}

static int blorp_io_reactor_release_interest(
    int fd,
    uint64_t generation,
    int interests
) {
    if (fd < 0 || interests == 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration** link = &__blorp_io_reactor.registrations;
    while (*link) {
        blorp_IoRegistration* reg = *link;
        if (reg->fd == fd && reg->generation == generation) {
            reg->interests &= ~interests;
            reg->ready_events &= reg->interests;
            bool remove = reg->interests == 0;
            if (remove) {
                *link = reg->next;
                if (reg->inner) blorp_tcp_inner_release(reg->inner);
                free(reg);
            }
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            blorp_io_reactor_wake_control();
            return 0;
        }
        link = &reg->next;
    }
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    return -1;
}

typedef struct {
    int fd;
    uint64_t generation;
    int interests;
    bool registered;
} blorp_IoRegistrationCleanup;

static void blorp_io_registration_cleanup_unregister(void* value) {
    blorp_IoRegistrationCleanup* cleanup =
        (blorp_IoRegistrationCleanup*)value;
    if (!cleanup || !cleanup->registered) return;
    cleanup->registered = false;
    (void)blorp_io_reactor_release_interest(
        cleanup->fd, cleanup->generation, cleanup->interests);
}

typedef struct {
    blorp_TcpInner* inner;
    bool active;
} blorp_TcpWriteOpCleanup;

static void blorp_tcp_write_op_cleanup_end(void* value) {
    blorp_TcpWriteOpCleanup* cleanup =
        (blorp_TcpWriteOpCleanup*)value;
    if (!cleanup || !cleanup->active) return;
    cleanup->active = false;
    blorp_tcp_inner_end_write_op(cleanup->inner);
}

typedef struct {
    blorp_TcpStream* stream;
    bool active;
} blorp_TcpProvisionalStreamCleanup;

static void blorp_tcp_provisional_stream_cleanup_release(void* value) {
    blorp_TcpProvisionalStreamCleanup* cleanup =
        (blorp_TcpProvisionalStreamCleanup*)value;
    if (!cleanup || !cleanup->active || !cleanup->stream) return;
    cleanup->active = false;
    blorp_release((void*)cleanup->stream);
}

static int blorp_tcp_inner_wait_for_reactor(
    blorp_TcpInner* inner,
    blorp_IoWaitKind wait_kind,
    int interest,
    int fd,
    uint64_t generation,
    long timeout_ms,
    blorp_IoWakeReason* reason_out
) {
    if (!reason_out) return -1;
    *reason_out = BLORP_IO_WAKE_NONE;
    if (!inner) return -1;
    blorp_tcp_inner_retain(inner);
    if (blorp_io_reactor_register_inner(inner, fd, generation, interest) != 0) {
        blorp_tcp_inner_release(inner);
        return -1;
    }

    blorp_IoRegistrationCleanup registration_cleanup = {
        .fd = fd,
        .generation = generation,
        .interests = interest,
        .registered = true
    };
    blorp_CancelCleanupFrame cleanup_frame;
    __blorp_task_cleanup_push_slow(
        &cleanup_frame,
        &registration_cleanup,
        &registration_cleanup,
        blorp_io_registration_cleanup_unregister);

    blorp_IoWakeReason reason =
        blorp_tcp_inner_park_current_fiber(
            inner, wait_kind, fd, generation, interest, timeout_ms);
    if (reason == BLORP_IO_WAKE_NONE) {
        int ready =
            blorp_io_reactor_wait_ready(fd, generation, interest, timeout_ms);
        reason = ready > 0 ? BLORP_IO_WAKE_READY
            : ready == 0 ? BLORP_IO_WAKE_TIMEOUT
                         : BLORP_IO_WAKE_CLOSED;
    }

    blorp_io_registration_cleanup_unregister(&registration_cleanup);
    __blorp_task_cleanup_pop_slot_slow(&registration_cleanup);
    *reason_out = reason;
    blorp_tcp_inner_release(inner);
    return 0;
}

static void blorp_io_reactor_deadline_from_now(
    long timeout_ms,
    struct timespec* out
) {
    clock_gettime(CLOCK_REALTIME, out);
    out->tv_sec += timeout_ms / 1000;
    out->tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (out->tv_nsec >= 1000000000L) {
        out->tv_sec++;
        out->tv_nsec -= 1000000000L;
    }
}

static int blorp_io_reactor_wait_ready(
    int fd,
    uint64_t generation,
    int interests,
    long timeout_ms
) {
    if (fd < 0 || interests == 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    struct timespec deadline;
    bool has_deadline = timeout_ms >= 0;
    if (has_deadline) blorp_io_reactor_deadline_from_now(timeout_ms, &deadline);

    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    while (!__blorp_io_reactor.shutdown) {
        blorp_IoRegistration* reg =
            blorp_io_reactor_find_locked(fd, generation);
        if (!reg) {
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            return -1;
        }
        int ready = reg->ready_events & interests;
        if (ready != 0) {
            reg->ready_events &= ~ready;
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            return ready;
        }
        int wait_rc = has_deadline
            ? pthread_cond_timedwait(
                  &__blorp_io_reactor.ready_cond,
                  &__blorp_io_reactor.mutex,
                  &deadline)
            : pthread_cond_wait(
                  &__blorp_io_reactor.ready_cond,
                  &__blorp_io_reactor.mutex);
        if (wait_rc == ETIMEDOUT) {
            pthread_mutex_unlock(&__blorp_io_reactor.mutex);
            return 0;
        }
    }
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    return -1;
}

static int blorp_io_reactor_take_ready(
    int fd,
    uint64_t generation,
    int interests
) {
    if (fd < 0 || interests == 0) return -1;
    if (blorp_io_reactor_start() != 0) return -1;
    pthread_mutex_lock(&__blorp_io_reactor.mutex);
    blorp_IoRegistration* reg =
        blorp_io_reactor_find_locked(fd, generation);
    if (!reg) {
        pthread_mutex_unlock(&__blorp_io_reactor.mutex);
        return -1;
    }
    int ready = reg->ready_events & interests;
    if (ready != 0) reg->ready_events &= ~ready;
    pthread_mutex_unlock(&__blorp_io_reactor.mutex);
    return ready;
}

int blorp_io_reactor_smoke_test(void) {
    int fds[2];
    if (blorp_runtime_pipe_cloexec_nonblock(fds) != 0) return 10;
    uint64_t generation = 1;
    int result = 0;
    if (blorp_io_reactor_register_fd_for_smoke(
            fds[0], generation, BLORP_IO_INTEREST_READ) != 0) {
        result = 11;
        goto cleanup;
    }
    const unsigned char byte = 42;
    if (write(fds[1], &byte, 1) != 1) {
        result = 12;
        goto cleanup_registered;
    }
    int ready = blorp_io_reactor_wait_ready(
        fds[0], generation, BLORP_IO_INTEREST_READ, 5000);
    if ((ready & BLORP_IO_INTEREST_READ) == 0) {
        result = 13;
    }

cleanup_registered:
    blorp_io_reactor_update_interest(fds[0], generation, 0);
    blorp_io_reactor_unregister_inner(fds[0], generation);
cleanup:
    close(fds[0]);
    close(fds[1]);
    return result;
}

// Sentinel refcount for immortal singleton objects (nullary constructors like None)
#define BLORP_IMMORTAL_REFCOUNT LONG_MAX

// Slow path for release — called when refcount reaches zero.
// Separated so the fast path (decrement + check) can be inlined.
__attribute__((noinline))
static void blorp_release_slow_finish(blorp_Object* header, void* obj,
                                      blorp_destructor_fn destructor) {
    blorp_AllocMeta* meta = __alloc_meta_take(header);
    bool stats_tracked = meta && meta->stats_tracked;
    bool counted_in_current_epoch =
        stats_tracked && meta->stats_epoch == atomic_load(&global_mem_stats.epoch);
    size_t freed_size = meta ? meta->alloc_size : 0;
    if (destructor) destructor(obj);

    // Try to return to pool instead of freeing. The hot header stores only the
    // pool class; exact byte size is cold metadata for stats/leak modes.
    // Disable pool when AddressSanitizer is active — ASan tracks malloc/free precisely
    // and the pool's memory reuse bypasses that tracking, causing false positives.
#if defined(BLORP_ASAN)
    free(obj);
#else
    int cls = header->alloc_class == BLORP_ALLOC_CLASS_DIRECT
        ? -1
        : (int)header->alloc_class;
    if (cls >= 0 && blorp_pool_count[cls] < BLORP_POOL_MAX_DEPTH) {
        // Push onto free list — reuse first 8 bytes as next pointer
        *(void**)obj = blorp_pool_free[cls];
        blorp_pool_free[cls] = obj;
        blorp_pool_count[cls]++;
    } else {
        free(obj);
    }
#endif

    if (__blorp_stats_enabled && counted_in_current_epoch) {
        global_mem_stats.total_releases++;
        global_mem_stats.current_objects--;
        global_mem_stats.bytes_allocated -= (long)freed_size;
    }
    free(meta);
}

static void blorp_release_slow(blorp_Object* header, void* obj) {
    blorp_release_slow_finish(header, obj,
        blorp_destructor_for_id(header->destructor_id));
}

// Extern entry point for precompiled runtime (runtime_decl.c inline fast path calls this)
void blorp_release_slow_extern(void* obj) {
    blorp_Object* header = (blorp_Object*)obj;
    blorp_release_slow(header, obj);
}

// Extern entry point for ARC-only values whose layouts cannot have nested destructors.
void blorp_release_arc_only_slow_extern(void* obj) {
    blorp_Object* header = (blorp_Object*)obj;
    blorp_release_slow_finish(header, obj, NULL);
}

// Single-threaded mode: use plain increment/decrement instead of atomics (14x cheaper)
#ifdef BLORP_SINGLE_THREADED
  #define BLORP_RC_LOAD(p)       (*(long*)(&(p)))
  #define BLORP_RC_INC(p)        (++(*(long*)(&(p))))
  #define BLORP_RC_DEC_PREV(p)   ((*(long*)(&(p)))--)

#else
  #define BLORP_RC_LOAD(p)       atomic_load(&(p))
  #define BLORP_RC_INC(p)        atomic_fetch_add(&(p), 1)
  #define BLORP_RC_DEC_PREV(p)   atomic_fetch_sub(&(p), 1)
#endif

__attribute__((always_inline))
inline void* blorp_retain(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return NULL;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return obj;
    BLORP_RC_INC(header->refcount);
    return obj;
}

__attribute__((always_inline))
inline void blorp_release(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return;
    long prev = BLORP_RC_DEC_PREV(header->refcount);
    if (__builtin_expect(prev == 1, 0)) {
        blorp_release_slow(header, obj);
    }
}

__attribute__((always_inline))
inline void blorp_release_arc_only(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return;
    long prev = BLORP_RC_DEC_PREV(header->refcount);
    if (__builtin_expect(prev == 1, 0)) {
        blorp_release_slow_finish(header, obj, NULL);
    }
}

__attribute__((always_inline))
inline bool blorp_is_unique(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return false;
    blorp_Object* header = (blorp_Object*)obj;
#ifdef BLORP_SINGLE_THREADED
    return header->refcount == 1;
#else
    return atomic_load_explicit(&header->refcount, memory_order_relaxed) == 1;
#endif
}

// Caller-side move: decrement refcount without freeing.
// Used for x = f(x, ...) patterns where the function's entry retain
// will immediately bring the refcount back, enabling in-place COW.
void blorp_move_ref(void* obj) {
    if (obj == NULL) return;
    blorp_Object* header = (blorp_Object*)obj;
    if (BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT) return;
    // Unconditional decrement — caller guarantees refcount > 1
    // (checked via blorp_is_unique before calling).
    // Note: the is_unique check + move_ref is a two-step non-atomic TOCTOU
    // under concurrency. This is safe because codegen's is_move_eligible_call
    // only emits move_ref for thread-local variables.
    assert(BLORP_RC_LOAD(header->refcount) > 0 && "blorp_move_ref: refcount already zero");
    BLORP_RC_DEC_PREV(header->refcount);
}

// Non-inline wrapper for blorp_release — used as elem_release function pointer
void blorp_elem_release_fn(void* p) {
    if (p) blorp_release(p);
}

// List destructor — releases elements if elem_release is set, then no-op
// (flexible array member is freed with the struct by blorp_release)
static void blorp_list_destroy(void* obj) {
    blorp_List* list = (blorp_List*)obj;
    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release) {
        for (long i = 0; i < list->len; i++) {
            if (list->data[i]) list->elem_release(list->data[i]);
        }
    }
}

// Set elem_release on a list and retain all existing elements.
// Used by codegen after blorp_list_build — elements were added before elem_release was set,
// so they need to be retained now to balance the release in blorp_list_destroy.
void blorp_list_set_elem_release(blorp_List* list, void (*release_fn)(void*)) {
    if (!list || list->storage_mode != BLORP_LIST_STORAGE_POINTER || list->elem_release) return;  // already set or null list
    list->elem_release = release_fn;
    for (long i = 0; i < list->len; i++) {
        if (list->data[i]) blorp_retain(list->data[i]);
    }
}

// Set elem_release on a list WITHOUT retaining existing elements.
// Used for lists returned by C runtime functions (map, filter_map, etc.)
// where elements are either fresh (no other owner) or already retained by
// the C function (filter, reverse, concat, copy).
void blorp_list_init_elem_release(blorp_List* list, void (*release_fn)(void*)) {
    if (!list || list->storage_mode != BLORP_LIST_STORAGE_POINTER || list->elem_release) return;  // already set or null list
    list->elem_release = release_fn;
}

// Vector destructor — releases elements if elem_release is set
static void blorp_vector_destroy(void* obj) {
    blorp_Vector* v = (blorp_Vector*)obj;
    if (v->elem_release) {
        // Use capacity to cover all elements in 2D matrices (len=rows, capacity=rows*cols)
        for (long i = 0; i < v->capacity; i++) {
            if (v->data[i]) v->elem_release(v->data[i]);
        }
    }
}

// Set elem_release on a vector and retain all existing elements.
// Uses capacity to cover all elements in 2D matrices.
void blorp_vector_set_elem_release(blorp_Vector* v, void (*release_fn)(void*)) {
    if (!v || v->elem_release) return;
    v->elem_release = release_fn;
    BLORP_SET_DESTRUCTOR(v, blorp_vector_destroy);
    for (long i = 0; i < v->capacity; i++) {
        if (v->data[i]) blorp_retain(v->data[i]);
    }
}

// Set elem_release on a vector WITHOUT retaining existing elements.
// Used for vectors returned by C runtime functions where elements are fresh.
void blorp_vector_init_elem_release(blorp_Vector* v, void (*release_fn)(void*)) {
    if (!v || v->elem_release) return;
    v->elem_release = release_fn;
    BLORP_SET_DESTRUCTOR(v, blorp_vector_destroy);
}

// ============================================================================
// Safe Arithmetic (default behavior)
// - Integer division/modulo by zero returns 0 (Option variants are separate)
// - Float division uses IEEE 754 (Inf/NaN on zero — well-defined)
// - Addition/subtraction/multiplication use wrapping on overflow via -fwrapv
//   (two's complement, well-defined, zero overhead)
// ============================================================================

// 0-returning integer division (used by Tensor/Vector element-wise ops and unsafe_div)
// Guards against LONG_MIN / -1 which is UB in C (SIGFPE on x86-64)
long blorp_checked_div_int(long a, long b) {
    return (b == 0 || (a == LONG_MIN && b == -1)) ? 0 : a / b;
}

// 0-returning integer modulo (used by Tensor/Vector element-wise ops)
// Guards against LONG_MIN % -1 which is UB in C
long blorp_checked_mod_int(long a, long b) {
    return (b == 0 || (a == LONG_MIN && b == -1)) ? 0 : a % b;
}

// ============================================================================
// Unsafe Arithmetic (returns 0 on divide-by-zero instead of Option)
// ============================================================================

long blorp_unsafe_div_int(long a, long b) {
    return (b == 0 || (a == LONG_MIN && b == -1)) ? 0 : a / b;
}

long blorp_unsafe_mod_int(long a, long b) {
    return (b == 0 || (a == LONG_MIN && b == -1)) ? 0 : a % b;
}


// ============================================================================
// Boxing/Unboxing for Generics
// ============================================================================
// Box a stack-allocated struct value for storage in containers (tuples).
// Allocates a blorp_Object header + struct data, so blorp_release frees it.
static inline void* blorp_box_struct(void* data, size_t size) {
    void* boxed = blorp_alloc(sizeof(blorp_Object) + size);
    memcpy((char*)boxed + sizeof(blorp_Object), data, size);
    return boxed;
}

// Read a boxed struct back out of a container (e.g. tuple element).
// Mirrors [blorp_box_struct] — the struct data starts at sizeof(blorp_Object)
// past the pointer returned by boxing. Used when unboxing a value-record
// from a generic void* slot.
#define blorp_unbox_struct(ptr, type) \
    (*(type*)((char*)(ptr) + sizeof(blorp_Object)))

// Floats need bit-preserving casts when stored in generic types (void*).
// sizeof(double) == sizeof(void*) on 64-bit systems.

static inline void* blorp_box_float(double f) {
    union { double d; void* p; } u;
    u.d = f;
    return u.p;
}

static inline double blorp_unbox_float(void* p) {
    union { void* p; double d; } u;
    u.p = p;
    return u.d;
}

// ============================================================================
// Float32 Boxing/Unboxing for Generics
// ============================================================================
// float is 4 bytes, void* is 8 bytes on 64-bit systems.
// Use uint32_t intermediate to preserve bit pattern.

static inline void* blorp_box_float32(float f) {
    union { float f; uint32_t u; } conv;
    conv.f = f;
    return (void*)(uintptr_t)conv.u;
}

static inline float blorp_unbox_float32(void* p) {
    union { uint32_t u; float f; } conv;
    conv.u = (uint32_t)(uintptr_t)p;
    return conv.f;
}

// ============================================================================
// Float16 Boxing/Unboxing for Generics
// ============================================================================
// _Float16 is 2 bytes. Use uint16_t intermediate to preserve bit pattern.
// Guarded: _Float16 requires GCC 12+/Clang 15+ on x86_64, or any ARM compiler.
#ifdef __FLT16_MAX__

static inline void* blorp_box_float16(_Float16 f) {
    union { _Float16 f; uint16_t u; } conv;
    conv.f = f;
    return (void*)(uintptr_t)conv.u;
}

static inline _Float16 blorp_unbox_float16(void* p) {
    union { uint16_t u; _Float16 f; } conv;
    conv.u = (uint16_t)(uintptr_t)p;
    return conv.f;
}

#endif // __FLT16_MAX__

// ============================================================================
// Int128 Boxing/Unboxing
// ============================================================================

// __int128 is 16 bytes, can't fit in a void*. Heap-allocate.
static inline void* blorp_box_int128(__int128 v) {
    void* p = blorp_alloc(sizeof(blorp_Object) + sizeof(__int128));
    *((__int128*)((char*)p + sizeof(blorp_Object))) = v;
    return p;
}

static inline __int128 blorp_unbox_int128(void* p) {
    return *((__int128*)((char*)p + sizeof(blorp_Object)));
}

static inline void* blorp_box_uint128(unsigned __int128 v) {
    void* p = blorp_alloc(sizeof(blorp_Object) + sizeof(unsigned __int128));
    *((unsigned __int128*)((char*)p + sizeof(blorp_Object))) = v;
    return p;
}

static inline unsigned __int128 blorp_unbox_uint128(void* p) {
    return *((unsigned __int128*)((char*)p + sizeof(blorp_Object)));
}

// ============================================================================
// String Operations
// ============================================================================

// Create a mutable string from a dynamic buffer (NOT interned, NOT immortal).
// Use this for runtime-built strings (to_string results, concatenation buffers, etc.)
static blorp_String* blorp_string_from_buf(const char* buf, long len) {
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_string_literal(const char* cstr) {
    long len = strlen(cstr);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, cstr, len);
    str->data[len] = '\0';
    // Make immortal so retain/release are no-ops
    ((blorp_Object*)str)->refcount = BLORP_IMMORTAL_REFCOUNT;
    // Immortal strings are runtime constants, not part of the measured program heap.
    blorp_untrack_allocated_object(str);
    return str;
}

// Forward declaration for immortal empty string singleton (initialized later)
static blorp_String* __blorp_empty_str;

// Mortal string allocation for codegen-emitted string literals.
// Returns a fresh ARC-managed string with refcount=1 (no interning).
blorp_String* blorp_string_create(const char* cstr) {
    long len = strlen(cstr);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    BLORP_TAG(str, "String");
    str->len = len;
    str->capacity = len;
    memcpy(str->data, cstr, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_string_concat(const blorp_String* a, const blorp_String* b) {
    if (!a && !b) return __blorp_empty_str;
    if (!a) return (blorp_String*)blorp_retain((void*)b);
    if (!b) return (blorp_String*)blorp_retain((void*)a);
    long new_len = (long)blorp_checked_add((size_t)a->len, (size_t)b->len);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + new_len + 1);
    result->len = new_len;
    result->capacity = new_len;
    memcpy(result->data, a->data, a->len);
    memcpy(result->data + a->len, b->data, b->len);
    result->data[new_len] = '\0';
    return result;
}

// Consuming string concat: creates result, then releases both inputs.
// Used for string interpolation where all parts are temporaries.
blorp_String* blorp_string_concat_consume(blorp_String* a, blorp_String* b) {
    if (!a && !b) return __blorp_empty_str;
    if (!a) return b;  // Transfer b's ownership
    if (!b) return a;  // Transfer a's ownership
    long new_len = (long)blorp_checked_add((size_t)a->len, (size_t)b->len);
    // Optimization: reuse a in-place if uniquely owned and has capacity
    if (blorp_is_unique(a) && a->capacity >= new_len) {
        memcpy(a->data + a->len, b->data, b->len);
        a->len = new_len;
        a->data[new_len] = '\0';
        blorp_release(b);
        return a;
    }
    // Allocate with growth headroom for repeated concat patterns
    size_t alloc_cap = blorp_checked_add((size_t)new_len, (size_t)(new_len >> 1));  // 1.5x capacity
    if (alloc_cap < (size_t)new_len + 16) alloc_cap = (size_t)new_len + 16;
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + alloc_cap + 1);
    result->len = new_len;
    result->capacity = (long)alloc_cap;
    memcpy(result->data, a->data, a->len);
    memcpy(result->data + a->len, b->data, b->len);
    result->data[new_len] = '\0';
    blorp_release(a);
    blorp_release(b);
    return result;
}

blorp_String* blorp_string_concat_many(long count, ...) {
    va_list args;
    // First pass: compute total length
    va_start(args, count);
    size_t total = 0;
    for (long i = 0; i < count; i++) {
        blorp_String* s = va_arg(args, blorp_String*);
        if (s) total += (size_t)s->len;
    }
    va_end(args);
    if (total == 0) {
        // Release all inputs
        va_start(args, count);
        for (long i = 0; i < count; i++) {
            blorp_String* s = va_arg(args, blorp_String*);
            if (s) blorp_release(s);
        }
        va_end(args);
        return __blorp_empty_str;
    }
    // Allocate result
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + total + 1);
    result->len = (long)total;
    result->capacity = (long)total;
    // Second pass: copy data and release inputs
    va_start(args, count);
    size_t offset = 0;
    for (long i = 0; i < count; i++) {
        blorp_String* s = va_arg(args, blorp_String*);
        if (s) {
            memcpy(result->data + offset, s->data, s->len);
            offset += (size_t)s->len;
            blorp_release(s);
        }
    }
    va_end(args);
    result->data[total] = '\0';
    return result;
}

bool blorp_string_eq(const blorp_String* a, const blorp_String* b) {
    if (a == b) return true;
    if (!a && !b) return true;
    if (!a || !b) return false;
    if (a->len != b->len) return false;
    return memcmp(a->data, b->data, a->len) == 0;
}

bool blorp_string_eq_cstr(const blorp_String* s, const char* cstr) {
    if (!s && (!cstr || cstr[0] == '\0')) return true;
    if (!s || !cstr) return false;
    long len = strlen(cstr);
    if (s->len != len) return false;
    return memcmp(s->data, cstr, len) == 0;
}

// Consuming string eq: compares, then releases both inputs.
bool blorp_string_eq_consume(blorp_String* a, blorp_String* b) {
    bool result = blorp_string_eq(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

long blorp_string_compare(const blorp_String* a, const blorp_String* b) {
    if (!a && !b) return 0;
    if (!a) return -1;
    if (!b) return 1;
    long min_len = a->len < b->len ? a->len : b->len;
    int cmp = memcmp(a->data, b->data, min_len);
    if (cmp != 0) return cmp < 0 ? -1 : 1;
    if (a->len < b->len) return -1;
    if (a->len > b->len) return 1;
    return 0;
}

// Consuming string compare: compares, then releases both inputs.
long blorp_string_compare_consume(blorp_String* a, blorp_String* b) {
    long result = blorp_string_compare(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

// (removed blorp_char_at — now IR intrinsic)

// Encode a Unicode codepoint as UTF-8 into buf (up to 4 bytes). Returns byte count.
static int blorp_utf8_encode(int32_t cp, unsigned char* buf) {
    if (cp < 0) cp = 0xFFFD;
    if (cp <= 0x7F) {
        buf[0] = (unsigned char)cp;
        return 1;
    } else if (cp <= 0x7FF) {
        buf[0] = (unsigned char)(0xC0 | (cp >> 6));
        buf[1] = (unsigned char)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp <= 0xFFFF) {
        buf[0] = (unsigned char)(0xE0 | (cp >> 12));
        buf[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (unsigned char)(0x80 | (cp & 0x3F));
        return 3;
    } else if (cp <= 0x10FFFF) {
        buf[0] = (unsigned char)(0xF0 | (cp >> 18));
        buf[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = (unsigned char)(0x80 | (cp & 0x3F));
        return 4;
    } else {
        // Replacement character U+FFFD
        buf[0] = 0xEF; buf[1] = 0xBF; buf[2] = 0xBD;
        return 3;
    }
}

// Unicode default case mapping tables generated from Python
// unicodedata 16.0.0. Keep in sync with Python-style String casing tests.
typedef struct {
    int32_t start;
    int32_t end;
    int32_t delta;
} blorp_unicode_case_range;

typedef struct {
    int32_t codepoint;
    uint8_t length;
    int32_t mapping[3];
} blorp_unicode_case_special;

typedef struct {
    int32_t codepoint;
    long start;
    int length;
    bool valid;
} blorp_utf8_span;

static const blorp_unicode_case_range blorp_upper_ranges[] = {
    {0x0061, 0x007A, -32},
    {0x00B5, 0x00B5, 743},
    {0x00E0, 0x00F6, -32},
    {0x00F8, 0x00FE, -32},
    {0x00FF, 0x00FF, 121},
    {0x0101, 0x0101, -1},
    {0x0103, 0x0103, -1},
    {0x0105, 0x0105, -1},
    {0x0107, 0x0107, -1},
    {0x0109, 0x0109, -1},
    {0x010B, 0x010B, -1},
    {0x010D, 0x010D, -1},
    {0x010F, 0x010F, -1},
    {0x0111, 0x0111, -1},
    {0x0113, 0x0113, -1},
    {0x0115, 0x0115, -1},
    {0x0117, 0x0117, -1},
    {0x0119, 0x0119, -1},
    {0x011B, 0x011B, -1},
    {0x011D, 0x011D, -1},
    {0x011F, 0x011F, -1},
    {0x0121, 0x0121, -1},
    {0x0123, 0x0123, -1},
    {0x0125, 0x0125, -1},
    {0x0127, 0x0127, -1},
    {0x0129, 0x0129, -1},
    {0x012B, 0x012B, -1},
    {0x012D, 0x012D, -1},
    {0x012F, 0x012F, -1},
    {0x0131, 0x0131, -232},
    {0x0133, 0x0133, -1},
    {0x0135, 0x0135, -1},
    {0x0137, 0x0137, -1},
    {0x013A, 0x013A, -1},
    {0x013C, 0x013C, -1},
    {0x013E, 0x013E, -1},
    {0x0140, 0x0140, -1},
    {0x0142, 0x0142, -1},
    {0x0144, 0x0144, -1},
    {0x0146, 0x0146, -1},
    {0x0148, 0x0148, -1},
    {0x014B, 0x014B, -1},
    {0x014D, 0x014D, -1},
    {0x014F, 0x014F, -1},
    {0x0151, 0x0151, -1},
    {0x0153, 0x0153, -1},
    {0x0155, 0x0155, -1},
    {0x0157, 0x0157, -1},
    {0x0159, 0x0159, -1},
    {0x015B, 0x015B, -1},
    {0x015D, 0x015D, -1},
    {0x015F, 0x015F, -1},
    {0x0161, 0x0161, -1},
    {0x0163, 0x0163, -1},
    {0x0165, 0x0165, -1},
    {0x0167, 0x0167, -1},
    {0x0169, 0x0169, -1},
    {0x016B, 0x016B, -1},
    {0x016D, 0x016D, -1},
    {0x016F, 0x016F, -1},
    {0x0171, 0x0171, -1},
    {0x0173, 0x0173, -1},
    {0x0175, 0x0175, -1},
    {0x0177, 0x0177, -1},
    {0x017A, 0x017A, -1},
    {0x017C, 0x017C, -1},
    {0x017E, 0x017E, -1},
    {0x017F, 0x017F, -300},
    {0x0180, 0x0180, 195},
    {0x0183, 0x0183, -1},
    {0x0185, 0x0185, -1},
    {0x0188, 0x0188, -1},
    {0x018C, 0x018C, -1},
    {0x0192, 0x0192, -1},
    {0x0195, 0x0195, 97},
    {0x0199, 0x0199, -1},
    {0x019A, 0x019A, 163},
    {0x019B, 0x019B, 42561},
    {0x019E, 0x019E, 130},
    {0x01A1, 0x01A1, -1},
    {0x01A3, 0x01A3, -1},
    {0x01A5, 0x01A5, -1},
    {0x01A8, 0x01A8, -1},
    {0x01AD, 0x01AD, -1},
    {0x01B0, 0x01B0, -1},
    {0x01B4, 0x01B4, -1},
    {0x01B6, 0x01B6, -1},
    {0x01B9, 0x01B9, -1},
    {0x01BD, 0x01BD, -1},
    {0x01BF, 0x01BF, 56},
    {0x01C5, 0x01C5, -1},
    {0x01C6, 0x01C6, -2},
    {0x01C8, 0x01C8, -1},
    {0x01C9, 0x01C9, -2},
    {0x01CB, 0x01CB, -1},
    {0x01CC, 0x01CC, -2},
    {0x01CE, 0x01CE, -1},
    {0x01D0, 0x01D0, -1},
    {0x01D2, 0x01D2, -1},
    {0x01D4, 0x01D4, -1},
    {0x01D6, 0x01D6, -1},
    {0x01D8, 0x01D8, -1},
    {0x01DA, 0x01DA, -1},
    {0x01DC, 0x01DC, -1},
    {0x01DD, 0x01DD, -79},
    {0x01DF, 0x01DF, -1},
    {0x01E1, 0x01E1, -1},
    {0x01E3, 0x01E3, -1},
    {0x01E5, 0x01E5, -1},
    {0x01E7, 0x01E7, -1},
    {0x01E9, 0x01E9, -1},
    {0x01EB, 0x01EB, -1},
    {0x01ED, 0x01ED, -1},
    {0x01EF, 0x01EF, -1},
    {0x01F2, 0x01F2, -1},
    {0x01F3, 0x01F3, -2},
    {0x01F5, 0x01F5, -1},
    {0x01F9, 0x01F9, -1},
    {0x01FB, 0x01FB, -1},
    {0x01FD, 0x01FD, -1},
    {0x01FF, 0x01FF, -1},
    {0x0201, 0x0201, -1},
    {0x0203, 0x0203, -1},
    {0x0205, 0x0205, -1},
    {0x0207, 0x0207, -1},
    {0x0209, 0x0209, -1},
    {0x020B, 0x020B, -1},
    {0x020D, 0x020D, -1},
    {0x020F, 0x020F, -1},
    {0x0211, 0x0211, -1},
    {0x0213, 0x0213, -1},
    {0x0215, 0x0215, -1},
    {0x0217, 0x0217, -1},
    {0x0219, 0x0219, -1},
    {0x021B, 0x021B, -1},
    {0x021D, 0x021D, -1},
    {0x021F, 0x021F, -1},
    {0x0223, 0x0223, -1},
    {0x0225, 0x0225, -1},
    {0x0227, 0x0227, -1},
    {0x0229, 0x0229, -1},
    {0x022B, 0x022B, -1},
    {0x022D, 0x022D, -1},
    {0x022F, 0x022F, -1},
    {0x0231, 0x0231, -1},
    {0x0233, 0x0233, -1},
    {0x023C, 0x023C, -1},
    {0x023F, 0x0240, 10815},
    {0x0242, 0x0242, -1},
    {0x0247, 0x0247, -1},
    {0x0249, 0x0249, -1},
    {0x024B, 0x024B, -1},
    {0x024D, 0x024D, -1},
    {0x024F, 0x024F, -1},
    {0x0250, 0x0250, 10783},
    {0x0251, 0x0251, 10780},
    {0x0252, 0x0252, 10782},
    {0x0253, 0x0253, -210},
    {0x0254, 0x0254, -206},
    {0x0256, 0x0257, -205},
    {0x0259, 0x0259, -202},
    {0x025B, 0x025B, -203},
    {0x025C, 0x025C, 42319},
    {0x0260, 0x0260, -205},
    {0x0261, 0x0261, 42315},
    {0x0263, 0x0263, -207},
    {0x0264, 0x0264, 42343},
    {0x0265, 0x0265, 42280},
    {0x0266, 0x0266, 42308},
    {0x0268, 0x0268, -209},
    {0x0269, 0x0269, -211},
    {0x026A, 0x026A, 42308},
    {0x026B, 0x026B, 10743},
    {0x026C, 0x026C, 42305},
    {0x026F, 0x026F, -211},
    {0x0271, 0x0271, 10749},
    {0x0272, 0x0272, -213},
    {0x0275, 0x0275, -214},
    {0x027D, 0x027D, 10727},
    {0x0280, 0x0280, -218},
    {0x0282, 0x0282, 42307},
    {0x0283, 0x0283, -218},
    {0x0287, 0x0287, 42282},
    {0x0288, 0x0288, -218},
    {0x0289, 0x0289, -69},
    {0x028A, 0x028B, -217},
    {0x028C, 0x028C, -71},
    {0x0292, 0x0292, -219},
    {0x029D, 0x029D, 42261},
    {0x029E, 0x029E, 42258},
    {0x0345, 0x0345, 84},
    {0x0371, 0x0371, -1},
    {0x0373, 0x0373, -1},
    {0x0377, 0x0377, -1},
    {0x037B, 0x037D, 130},
    {0x03AC, 0x03AC, -38},
    {0x03AD, 0x03AF, -37},
    {0x03B1, 0x03C1, -32},
    {0x03C2, 0x03C2, -31},
    {0x03C3, 0x03CB, -32},
    {0x03CC, 0x03CC, -64},
    {0x03CD, 0x03CE, -63},
    {0x03D0, 0x03D0, -62},
    {0x03D1, 0x03D1, -57},
    {0x03D5, 0x03D5, -47},
    {0x03D6, 0x03D6, -54},
    {0x03D7, 0x03D7, -8},
    {0x03D9, 0x03D9, -1},
    {0x03DB, 0x03DB, -1},
    {0x03DD, 0x03DD, -1},
    {0x03DF, 0x03DF, -1},
    {0x03E1, 0x03E1, -1},
    {0x03E3, 0x03E3, -1},
    {0x03E5, 0x03E5, -1},
    {0x03E7, 0x03E7, -1},
    {0x03E9, 0x03E9, -1},
    {0x03EB, 0x03EB, -1},
    {0x03ED, 0x03ED, -1},
    {0x03EF, 0x03EF, -1},
    {0x03F0, 0x03F0, -86},
    {0x03F1, 0x03F1, -80},
    {0x03F2, 0x03F2, 7},
    {0x03F3, 0x03F3, -116},
    {0x03F5, 0x03F5, -96},
    {0x03F8, 0x03F8, -1},
    {0x03FB, 0x03FB, -1},
    {0x0430, 0x044F, -32},
    {0x0450, 0x045F, -80},
    {0x0461, 0x0461, -1},
    {0x0463, 0x0463, -1},
    {0x0465, 0x0465, -1},
    {0x0467, 0x0467, -1},
    {0x0469, 0x0469, -1},
    {0x046B, 0x046B, -1},
    {0x046D, 0x046D, -1},
    {0x046F, 0x046F, -1},
    {0x0471, 0x0471, -1},
    {0x0473, 0x0473, -1},
    {0x0475, 0x0475, -1},
    {0x0477, 0x0477, -1},
    {0x0479, 0x0479, -1},
    {0x047B, 0x047B, -1},
    {0x047D, 0x047D, -1},
    {0x047F, 0x047F, -1},
    {0x0481, 0x0481, -1},
    {0x048B, 0x048B, -1},
    {0x048D, 0x048D, -1},
    {0x048F, 0x048F, -1},
    {0x0491, 0x0491, -1},
    {0x0493, 0x0493, -1},
    {0x0495, 0x0495, -1},
    {0x0497, 0x0497, -1},
    {0x0499, 0x0499, -1},
    {0x049B, 0x049B, -1},
    {0x049D, 0x049D, -1},
    {0x049F, 0x049F, -1},
    {0x04A1, 0x04A1, -1},
    {0x04A3, 0x04A3, -1},
    {0x04A5, 0x04A5, -1},
    {0x04A7, 0x04A7, -1},
    {0x04A9, 0x04A9, -1},
    {0x04AB, 0x04AB, -1},
    {0x04AD, 0x04AD, -1},
    {0x04AF, 0x04AF, -1},
    {0x04B1, 0x04B1, -1},
    {0x04B3, 0x04B3, -1},
    {0x04B5, 0x04B5, -1},
    {0x04B7, 0x04B7, -1},
    {0x04B9, 0x04B9, -1},
    {0x04BB, 0x04BB, -1},
    {0x04BD, 0x04BD, -1},
    {0x04BF, 0x04BF, -1},
    {0x04C2, 0x04C2, -1},
    {0x04C4, 0x04C4, -1},
    {0x04C6, 0x04C6, -1},
    {0x04C8, 0x04C8, -1},
    {0x04CA, 0x04CA, -1},
    {0x04CC, 0x04CC, -1},
    {0x04CE, 0x04CE, -1},
    {0x04CF, 0x04CF, -15},
    {0x04D1, 0x04D1, -1},
    {0x04D3, 0x04D3, -1},
    {0x04D5, 0x04D5, -1},
    {0x04D7, 0x04D7, -1},
    {0x04D9, 0x04D9, -1},
    {0x04DB, 0x04DB, -1},
    {0x04DD, 0x04DD, -1},
    {0x04DF, 0x04DF, -1},
    {0x04E1, 0x04E1, -1},
    {0x04E3, 0x04E3, -1},
    {0x04E5, 0x04E5, -1},
    {0x04E7, 0x04E7, -1},
    {0x04E9, 0x04E9, -1},
    {0x04EB, 0x04EB, -1},
    {0x04ED, 0x04ED, -1},
    {0x04EF, 0x04EF, -1},
    {0x04F1, 0x04F1, -1},
    {0x04F3, 0x04F3, -1},
    {0x04F5, 0x04F5, -1},
    {0x04F7, 0x04F7, -1},
    {0x04F9, 0x04F9, -1},
    {0x04FB, 0x04FB, -1},
    {0x04FD, 0x04FD, -1},
    {0x04FF, 0x04FF, -1},
    {0x0501, 0x0501, -1},
    {0x0503, 0x0503, -1},
    {0x0505, 0x0505, -1},
    {0x0507, 0x0507, -1},
    {0x0509, 0x0509, -1},
    {0x050B, 0x050B, -1},
    {0x050D, 0x050D, -1},
    {0x050F, 0x050F, -1},
    {0x0511, 0x0511, -1},
    {0x0513, 0x0513, -1},
    {0x0515, 0x0515, -1},
    {0x0517, 0x0517, -1},
    {0x0519, 0x0519, -1},
    {0x051B, 0x051B, -1},
    {0x051D, 0x051D, -1},
    {0x051F, 0x051F, -1},
    {0x0521, 0x0521, -1},
    {0x0523, 0x0523, -1},
    {0x0525, 0x0525, -1},
    {0x0527, 0x0527, -1},
    {0x0529, 0x0529, -1},
    {0x052B, 0x052B, -1},
    {0x052D, 0x052D, -1},
    {0x052F, 0x052F, -1},
    {0x0561, 0x0586, -48},
    {0x10D0, 0x10FA, 3008},
    {0x10FD, 0x10FF, 3008},
    {0x13F8, 0x13FD, -8},
    {0x1C80, 0x1C80, -6254},
    {0x1C81, 0x1C81, -6253},
    {0x1C82, 0x1C82, -6244},
    {0x1C83, 0x1C84, -6242},
    {0x1C85, 0x1C85, -6243},
    {0x1C86, 0x1C86, -6236},
    {0x1C87, 0x1C87, -6181},
    {0x1C88, 0x1C88, 35266},
    {0x1C8A, 0x1C8A, -1},
    {0x1D79, 0x1D79, 35332},
    {0x1D7D, 0x1D7D, 3814},
    {0x1D8E, 0x1D8E, 35384},
    {0x1E01, 0x1E01, -1},
    {0x1E03, 0x1E03, -1},
    {0x1E05, 0x1E05, -1},
    {0x1E07, 0x1E07, -1},
    {0x1E09, 0x1E09, -1},
    {0x1E0B, 0x1E0B, -1},
    {0x1E0D, 0x1E0D, -1},
    {0x1E0F, 0x1E0F, -1},
    {0x1E11, 0x1E11, -1},
    {0x1E13, 0x1E13, -1},
    {0x1E15, 0x1E15, -1},
    {0x1E17, 0x1E17, -1},
    {0x1E19, 0x1E19, -1},
    {0x1E1B, 0x1E1B, -1},
    {0x1E1D, 0x1E1D, -1},
    {0x1E1F, 0x1E1F, -1},
    {0x1E21, 0x1E21, -1},
    {0x1E23, 0x1E23, -1},
    {0x1E25, 0x1E25, -1},
    {0x1E27, 0x1E27, -1},
    {0x1E29, 0x1E29, -1},
    {0x1E2B, 0x1E2B, -1},
    {0x1E2D, 0x1E2D, -1},
    {0x1E2F, 0x1E2F, -1},
    {0x1E31, 0x1E31, -1},
    {0x1E33, 0x1E33, -1},
    {0x1E35, 0x1E35, -1},
    {0x1E37, 0x1E37, -1},
    {0x1E39, 0x1E39, -1},
    {0x1E3B, 0x1E3B, -1},
    {0x1E3D, 0x1E3D, -1},
    {0x1E3F, 0x1E3F, -1},
    {0x1E41, 0x1E41, -1},
    {0x1E43, 0x1E43, -1},
    {0x1E45, 0x1E45, -1},
    {0x1E47, 0x1E47, -1},
    {0x1E49, 0x1E49, -1},
    {0x1E4B, 0x1E4B, -1},
    {0x1E4D, 0x1E4D, -1},
    {0x1E4F, 0x1E4F, -1},
    {0x1E51, 0x1E51, -1},
    {0x1E53, 0x1E53, -1},
    {0x1E55, 0x1E55, -1},
    {0x1E57, 0x1E57, -1},
    {0x1E59, 0x1E59, -1},
    {0x1E5B, 0x1E5B, -1},
    {0x1E5D, 0x1E5D, -1},
    {0x1E5F, 0x1E5F, -1},
    {0x1E61, 0x1E61, -1},
    {0x1E63, 0x1E63, -1},
    {0x1E65, 0x1E65, -1},
    {0x1E67, 0x1E67, -1},
    {0x1E69, 0x1E69, -1},
    {0x1E6B, 0x1E6B, -1},
    {0x1E6D, 0x1E6D, -1},
    {0x1E6F, 0x1E6F, -1},
    {0x1E71, 0x1E71, -1},
    {0x1E73, 0x1E73, -1},
    {0x1E75, 0x1E75, -1},
    {0x1E77, 0x1E77, -1},
    {0x1E79, 0x1E79, -1},
    {0x1E7B, 0x1E7B, -1},
    {0x1E7D, 0x1E7D, -1},
    {0x1E7F, 0x1E7F, -1},
    {0x1E81, 0x1E81, -1},
    {0x1E83, 0x1E83, -1},
    {0x1E85, 0x1E85, -1},
    {0x1E87, 0x1E87, -1},
    {0x1E89, 0x1E89, -1},
    {0x1E8B, 0x1E8B, -1},
    {0x1E8D, 0x1E8D, -1},
    {0x1E8F, 0x1E8F, -1},
    {0x1E91, 0x1E91, -1},
    {0x1E93, 0x1E93, -1},
    {0x1E95, 0x1E95, -1},
    {0x1E9B, 0x1E9B, -59},
    {0x1EA1, 0x1EA1, -1},
    {0x1EA3, 0x1EA3, -1},
    {0x1EA5, 0x1EA5, -1},
    {0x1EA7, 0x1EA7, -1},
    {0x1EA9, 0x1EA9, -1},
    {0x1EAB, 0x1EAB, -1},
    {0x1EAD, 0x1EAD, -1},
    {0x1EAF, 0x1EAF, -1},
    {0x1EB1, 0x1EB1, -1},
    {0x1EB3, 0x1EB3, -1},
    {0x1EB5, 0x1EB5, -1},
    {0x1EB7, 0x1EB7, -1},
    {0x1EB9, 0x1EB9, -1},
    {0x1EBB, 0x1EBB, -1},
    {0x1EBD, 0x1EBD, -1},
    {0x1EBF, 0x1EBF, -1},
    {0x1EC1, 0x1EC1, -1},
    {0x1EC3, 0x1EC3, -1},
    {0x1EC5, 0x1EC5, -1},
    {0x1EC7, 0x1EC7, -1},
    {0x1EC9, 0x1EC9, -1},
    {0x1ECB, 0x1ECB, -1},
    {0x1ECD, 0x1ECD, -1},
    {0x1ECF, 0x1ECF, -1},
    {0x1ED1, 0x1ED1, -1},
    {0x1ED3, 0x1ED3, -1},
    {0x1ED5, 0x1ED5, -1},
    {0x1ED7, 0x1ED7, -1},
    {0x1ED9, 0x1ED9, -1},
    {0x1EDB, 0x1EDB, -1},
    {0x1EDD, 0x1EDD, -1},
    {0x1EDF, 0x1EDF, -1},
    {0x1EE1, 0x1EE1, -1},
    {0x1EE3, 0x1EE3, -1},
    {0x1EE5, 0x1EE5, -1},
    {0x1EE7, 0x1EE7, -1},
    {0x1EE9, 0x1EE9, -1},
    {0x1EEB, 0x1EEB, -1},
    {0x1EED, 0x1EED, -1},
    {0x1EEF, 0x1EEF, -1},
    {0x1EF1, 0x1EF1, -1},
    {0x1EF3, 0x1EF3, -1},
    {0x1EF5, 0x1EF5, -1},
    {0x1EF7, 0x1EF7, -1},
    {0x1EF9, 0x1EF9, -1},
    {0x1EFB, 0x1EFB, -1},
    {0x1EFD, 0x1EFD, -1},
    {0x1EFF, 0x1EFF, -1},
    {0x1F00, 0x1F07, 8},
    {0x1F10, 0x1F15, 8},
    {0x1F20, 0x1F27, 8},
    {0x1F30, 0x1F37, 8},
    {0x1F40, 0x1F45, 8},
    {0x1F51, 0x1F51, 8},
    {0x1F53, 0x1F53, 8},
    {0x1F55, 0x1F55, 8},
    {0x1F57, 0x1F57, 8},
    {0x1F60, 0x1F67, 8},
    {0x1F70, 0x1F71, 74},
    {0x1F72, 0x1F75, 86},
    {0x1F76, 0x1F77, 100},
    {0x1F78, 0x1F79, 128},
    {0x1F7A, 0x1F7B, 112},
    {0x1F7C, 0x1F7D, 126},
    {0x1FB0, 0x1FB1, 8},
    {0x1FBE, 0x1FBE, -7205},
    {0x1FD0, 0x1FD1, 8},
    {0x1FE0, 0x1FE1, 8},
    {0x1FE5, 0x1FE5, 7},
    {0x214E, 0x214E, -28},
    {0x2170, 0x217F, -16},
    {0x2184, 0x2184, -1},
    {0x24D0, 0x24E9, -26},
    {0x2C30, 0x2C5F, -48},
    {0x2C61, 0x2C61, -1},
    {0x2C65, 0x2C65, -10795},
    {0x2C66, 0x2C66, -10792},
    {0x2C68, 0x2C68, -1},
    {0x2C6A, 0x2C6A, -1},
    {0x2C6C, 0x2C6C, -1},
    {0x2C73, 0x2C73, -1},
    {0x2C76, 0x2C76, -1},
    {0x2C81, 0x2C81, -1},
    {0x2C83, 0x2C83, -1},
    {0x2C85, 0x2C85, -1},
    {0x2C87, 0x2C87, -1},
    {0x2C89, 0x2C89, -1},
    {0x2C8B, 0x2C8B, -1},
    {0x2C8D, 0x2C8D, -1},
    {0x2C8F, 0x2C8F, -1},
    {0x2C91, 0x2C91, -1},
    {0x2C93, 0x2C93, -1},
    {0x2C95, 0x2C95, -1},
    {0x2C97, 0x2C97, -1},
    {0x2C99, 0x2C99, -1},
    {0x2C9B, 0x2C9B, -1},
    {0x2C9D, 0x2C9D, -1},
    {0x2C9F, 0x2C9F, -1},
    {0x2CA1, 0x2CA1, -1},
    {0x2CA3, 0x2CA3, -1},
    {0x2CA5, 0x2CA5, -1},
    {0x2CA7, 0x2CA7, -1},
    {0x2CA9, 0x2CA9, -1},
    {0x2CAB, 0x2CAB, -1},
    {0x2CAD, 0x2CAD, -1},
    {0x2CAF, 0x2CAF, -1},
    {0x2CB1, 0x2CB1, -1},
    {0x2CB3, 0x2CB3, -1},
    {0x2CB5, 0x2CB5, -1},
    {0x2CB7, 0x2CB7, -1},
    {0x2CB9, 0x2CB9, -1},
    {0x2CBB, 0x2CBB, -1},
    {0x2CBD, 0x2CBD, -1},
    {0x2CBF, 0x2CBF, -1},
    {0x2CC1, 0x2CC1, -1},
    {0x2CC3, 0x2CC3, -1},
    {0x2CC5, 0x2CC5, -1},
    {0x2CC7, 0x2CC7, -1},
    {0x2CC9, 0x2CC9, -1},
    {0x2CCB, 0x2CCB, -1},
    {0x2CCD, 0x2CCD, -1},
    {0x2CCF, 0x2CCF, -1},
    {0x2CD1, 0x2CD1, -1},
    {0x2CD3, 0x2CD3, -1},
    {0x2CD5, 0x2CD5, -1},
    {0x2CD7, 0x2CD7, -1},
    {0x2CD9, 0x2CD9, -1},
    {0x2CDB, 0x2CDB, -1},
    {0x2CDD, 0x2CDD, -1},
    {0x2CDF, 0x2CDF, -1},
    {0x2CE1, 0x2CE1, -1},
    {0x2CE3, 0x2CE3, -1},
    {0x2CEC, 0x2CEC, -1},
    {0x2CEE, 0x2CEE, -1},
    {0x2CF3, 0x2CF3, -1},
    {0x2D00, 0x2D25, -7264},
    {0x2D27, 0x2D27, -7264},
    {0x2D2D, 0x2D2D, -7264},
    {0xA641, 0xA641, -1},
    {0xA643, 0xA643, -1},
    {0xA645, 0xA645, -1},
    {0xA647, 0xA647, -1},
    {0xA649, 0xA649, -1},
    {0xA64B, 0xA64B, -1},
    {0xA64D, 0xA64D, -1},
    {0xA64F, 0xA64F, -1},
    {0xA651, 0xA651, -1},
    {0xA653, 0xA653, -1},
    {0xA655, 0xA655, -1},
    {0xA657, 0xA657, -1},
    {0xA659, 0xA659, -1},
    {0xA65B, 0xA65B, -1},
    {0xA65D, 0xA65D, -1},
    {0xA65F, 0xA65F, -1},
    {0xA661, 0xA661, -1},
    {0xA663, 0xA663, -1},
    {0xA665, 0xA665, -1},
    {0xA667, 0xA667, -1},
    {0xA669, 0xA669, -1},
    {0xA66B, 0xA66B, -1},
    {0xA66D, 0xA66D, -1},
    {0xA681, 0xA681, -1},
    {0xA683, 0xA683, -1},
    {0xA685, 0xA685, -1},
    {0xA687, 0xA687, -1},
    {0xA689, 0xA689, -1},
    {0xA68B, 0xA68B, -1},
    {0xA68D, 0xA68D, -1},
    {0xA68F, 0xA68F, -1},
    {0xA691, 0xA691, -1},
    {0xA693, 0xA693, -1},
    {0xA695, 0xA695, -1},
    {0xA697, 0xA697, -1},
    {0xA699, 0xA699, -1},
    {0xA69B, 0xA69B, -1},
    {0xA723, 0xA723, -1},
    {0xA725, 0xA725, -1},
    {0xA727, 0xA727, -1},
    {0xA729, 0xA729, -1},
    {0xA72B, 0xA72B, -1},
    {0xA72D, 0xA72D, -1},
    {0xA72F, 0xA72F, -1},
    {0xA733, 0xA733, -1},
    {0xA735, 0xA735, -1},
    {0xA737, 0xA737, -1},
    {0xA739, 0xA739, -1},
    {0xA73B, 0xA73B, -1},
    {0xA73D, 0xA73D, -1},
    {0xA73F, 0xA73F, -1},
    {0xA741, 0xA741, -1},
    {0xA743, 0xA743, -1},
    {0xA745, 0xA745, -1},
    {0xA747, 0xA747, -1},
    {0xA749, 0xA749, -1},
    {0xA74B, 0xA74B, -1},
    {0xA74D, 0xA74D, -1},
    {0xA74F, 0xA74F, -1},
    {0xA751, 0xA751, -1},
    {0xA753, 0xA753, -1},
    {0xA755, 0xA755, -1},
    {0xA757, 0xA757, -1},
    {0xA759, 0xA759, -1},
    {0xA75B, 0xA75B, -1},
    {0xA75D, 0xA75D, -1},
    {0xA75F, 0xA75F, -1},
    {0xA761, 0xA761, -1},
    {0xA763, 0xA763, -1},
    {0xA765, 0xA765, -1},
    {0xA767, 0xA767, -1},
    {0xA769, 0xA769, -1},
    {0xA76B, 0xA76B, -1},
    {0xA76D, 0xA76D, -1},
    {0xA76F, 0xA76F, -1},
    {0xA77A, 0xA77A, -1},
    {0xA77C, 0xA77C, -1},
    {0xA77F, 0xA77F, -1},
    {0xA781, 0xA781, -1},
    {0xA783, 0xA783, -1},
    {0xA785, 0xA785, -1},
    {0xA787, 0xA787, -1},
    {0xA78C, 0xA78C, -1},
    {0xA791, 0xA791, -1},
    {0xA793, 0xA793, -1},
    {0xA794, 0xA794, 48},
    {0xA797, 0xA797, -1},
    {0xA799, 0xA799, -1},
    {0xA79B, 0xA79B, -1},
    {0xA79D, 0xA79D, -1},
    {0xA79F, 0xA79F, -1},
    {0xA7A1, 0xA7A1, -1},
    {0xA7A3, 0xA7A3, -1},
    {0xA7A5, 0xA7A5, -1},
    {0xA7A7, 0xA7A7, -1},
    {0xA7A9, 0xA7A9, -1},
    {0xA7B5, 0xA7B5, -1},
    {0xA7B7, 0xA7B7, -1},
    {0xA7B9, 0xA7B9, -1},
    {0xA7BB, 0xA7BB, -1},
    {0xA7BD, 0xA7BD, -1},
    {0xA7BF, 0xA7BF, -1},
    {0xA7C1, 0xA7C1, -1},
    {0xA7C3, 0xA7C3, -1},
    {0xA7C8, 0xA7C8, -1},
    {0xA7CA, 0xA7CA, -1},
    {0xA7CD, 0xA7CD, -1},
    {0xA7D1, 0xA7D1, -1},
    {0xA7D7, 0xA7D7, -1},
    {0xA7D9, 0xA7D9, -1},
    {0xA7DB, 0xA7DB, -1},
    {0xA7F6, 0xA7F6, -1},
    {0xAB53, 0xAB53, -928},
    {0xAB70, 0xABBF, -38864},
    {0xFF41, 0xFF5A, -32},
    {0x10428, 0x1044F, -40},
    {0x104D8, 0x104FB, -40},
    {0x10597, 0x105A1, -39},
    {0x105A3, 0x105B1, -39},
    {0x105B3, 0x105B9, -39},
    {0x105BB, 0x105BC, -39},
    {0x10CC0, 0x10CF2, -64},
    {0x10D70, 0x10D85, -32},
    {0x118C0, 0x118DF, -32},
    {0x16E60, 0x16E7F, -32},
    {0x1E922, 0x1E943, -34},
};

static const blorp_unicode_case_special blorp_upper_specials[] = {
    {0x00DF, 2, {0x0053, 0x0053, 0x0000}},
    {0x0149, 2, {0x02BC, 0x004E, 0x0000}},
    {0x01F0, 2, {0x004A, 0x030C, 0x0000}},
    {0x0390, 3, {0x0399, 0x0308, 0x0301}},
    {0x03B0, 3, {0x03A5, 0x0308, 0x0301}},
    {0x0587, 2, {0x0535, 0x0552, 0x0000}},
    {0x1E96, 2, {0x0048, 0x0331, 0x0000}},
    {0x1E97, 2, {0x0054, 0x0308, 0x0000}},
    {0x1E98, 2, {0x0057, 0x030A, 0x0000}},
    {0x1E99, 2, {0x0059, 0x030A, 0x0000}},
    {0x1E9A, 2, {0x0041, 0x02BE, 0x0000}},
    {0x1F50, 2, {0x03A5, 0x0313, 0x0000}},
    {0x1F52, 3, {0x03A5, 0x0313, 0x0300}},
    {0x1F54, 3, {0x03A5, 0x0313, 0x0301}},
    {0x1F56, 3, {0x03A5, 0x0313, 0x0342}},
    {0x1F80, 2, {0x1F08, 0x0399, 0x0000}},
    {0x1F81, 2, {0x1F09, 0x0399, 0x0000}},
    {0x1F82, 2, {0x1F0A, 0x0399, 0x0000}},
    {0x1F83, 2, {0x1F0B, 0x0399, 0x0000}},
    {0x1F84, 2, {0x1F0C, 0x0399, 0x0000}},
    {0x1F85, 2, {0x1F0D, 0x0399, 0x0000}},
    {0x1F86, 2, {0x1F0E, 0x0399, 0x0000}},
    {0x1F87, 2, {0x1F0F, 0x0399, 0x0000}},
    {0x1F88, 2, {0x1F08, 0x0399, 0x0000}},
    {0x1F89, 2, {0x1F09, 0x0399, 0x0000}},
    {0x1F8A, 2, {0x1F0A, 0x0399, 0x0000}},
    {0x1F8B, 2, {0x1F0B, 0x0399, 0x0000}},
    {0x1F8C, 2, {0x1F0C, 0x0399, 0x0000}},
    {0x1F8D, 2, {0x1F0D, 0x0399, 0x0000}},
    {0x1F8E, 2, {0x1F0E, 0x0399, 0x0000}},
    {0x1F8F, 2, {0x1F0F, 0x0399, 0x0000}},
    {0x1F90, 2, {0x1F28, 0x0399, 0x0000}},
    {0x1F91, 2, {0x1F29, 0x0399, 0x0000}},
    {0x1F92, 2, {0x1F2A, 0x0399, 0x0000}},
    {0x1F93, 2, {0x1F2B, 0x0399, 0x0000}},
    {0x1F94, 2, {0x1F2C, 0x0399, 0x0000}},
    {0x1F95, 2, {0x1F2D, 0x0399, 0x0000}},
    {0x1F96, 2, {0x1F2E, 0x0399, 0x0000}},
    {0x1F97, 2, {0x1F2F, 0x0399, 0x0000}},
    {0x1F98, 2, {0x1F28, 0x0399, 0x0000}},
    {0x1F99, 2, {0x1F29, 0x0399, 0x0000}},
    {0x1F9A, 2, {0x1F2A, 0x0399, 0x0000}},
    {0x1F9B, 2, {0x1F2B, 0x0399, 0x0000}},
    {0x1F9C, 2, {0x1F2C, 0x0399, 0x0000}},
    {0x1F9D, 2, {0x1F2D, 0x0399, 0x0000}},
    {0x1F9E, 2, {0x1F2E, 0x0399, 0x0000}},
    {0x1F9F, 2, {0x1F2F, 0x0399, 0x0000}},
    {0x1FA0, 2, {0x1F68, 0x0399, 0x0000}},
    {0x1FA1, 2, {0x1F69, 0x0399, 0x0000}},
    {0x1FA2, 2, {0x1F6A, 0x0399, 0x0000}},
    {0x1FA3, 2, {0x1F6B, 0x0399, 0x0000}},
    {0x1FA4, 2, {0x1F6C, 0x0399, 0x0000}},
    {0x1FA5, 2, {0x1F6D, 0x0399, 0x0000}},
    {0x1FA6, 2, {0x1F6E, 0x0399, 0x0000}},
    {0x1FA7, 2, {0x1F6F, 0x0399, 0x0000}},
    {0x1FA8, 2, {0x1F68, 0x0399, 0x0000}},
    {0x1FA9, 2, {0x1F69, 0x0399, 0x0000}},
    {0x1FAA, 2, {0x1F6A, 0x0399, 0x0000}},
    {0x1FAB, 2, {0x1F6B, 0x0399, 0x0000}},
    {0x1FAC, 2, {0x1F6C, 0x0399, 0x0000}},
    {0x1FAD, 2, {0x1F6D, 0x0399, 0x0000}},
    {0x1FAE, 2, {0x1F6E, 0x0399, 0x0000}},
    {0x1FAF, 2, {0x1F6F, 0x0399, 0x0000}},
    {0x1FB2, 2, {0x1FBA, 0x0399, 0x0000}},
    {0x1FB3, 2, {0x0391, 0x0399, 0x0000}},
    {0x1FB4, 2, {0x0386, 0x0399, 0x0000}},
    {0x1FB6, 2, {0x0391, 0x0342, 0x0000}},
    {0x1FB7, 3, {0x0391, 0x0342, 0x0399}},
    {0x1FBC, 2, {0x0391, 0x0399, 0x0000}},
    {0x1FC2, 2, {0x1FCA, 0x0399, 0x0000}},
    {0x1FC3, 2, {0x0397, 0x0399, 0x0000}},
    {0x1FC4, 2, {0x0389, 0x0399, 0x0000}},
    {0x1FC6, 2, {0x0397, 0x0342, 0x0000}},
    {0x1FC7, 3, {0x0397, 0x0342, 0x0399}},
    {0x1FCC, 2, {0x0397, 0x0399, 0x0000}},
    {0x1FD2, 3, {0x0399, 0x0308, 0x0300}},
    {0x1FD3, 3, {0x0399, 0x0308, 0x0301}},
    {0x1FD6, 2, {0x0399, 0x0342, 0x0000}},
    {0x1FD7, 3, {0x0399, 0x0308, 0x0342}},
    {0x1FE2, 3, {0x03A5, 0x0308, 0x0300}},
    {0x1FE3, 3, {0x03A5, 0x0308, 0x0301}},
    {0x1FE4, 2, {0x03A1, 0x0313, 0x0000}},
    {0x1FE6, 2, {0x03A5, 0x0342, 0x0000}},
    {0x1FE7, 3, {0x03A5, 0x0308, 0x0342}},
    {0x1FF2, 2, {0x1FFA, 0x0399, 0x0000}},
    {0x1FF3, 2, {0x03A9, 0x0399, 0x0000}},
    {0x1FF4, 2, {0x038F, 0x0399, 0x0000}},
    {0x1FF6, 2, {0x03A9, 0x0342, 0x0000}},
    {0x1FF7, 3, {0x03A9, 0x0342, 0x0399}},
    {0x1FFC, 2, {0x03A9, 0x0399, 0x0000}},
    {0xFB00, 2, {0x0046, 0x0046, 0x0000}},
    {0xFB01, 2, {0x0046, 0x0049, 0x0000}},
    {0xFB02, 2, {0x0046, 0x004C, 0x0000}},
    {0xFB03, 3, {0x0046, 0x0046, 0x0049}},
    {0xFB04, 3, {0x0046, 0x0046, 0x004C}},
    {0xFB05, 2, {0x0053, 0x0054, 0x0000}},
    {0xFB06, 2, {0x0053, 0x0054, 0x0000}},
    {0xFB13, 2, {0x0544, 0x0546, 0x0000}},
    {0xFB14, 2, {0x0544, 0x0535, 0x0000}},
    {0xFB15, 2, {0x0544, 0x053B, 0x0000}},
    {0xFB16, 2, {0x054E, 0x0546, 0x0000}},
    {0xFB17, 2, {0x0544, 0x053D, 0x0000}},
};

static const blorp_unicode_case_range blorp_lower_ranges[] = {
    {0x0041, 0x005A, 32},
    {0x00C0, 0x00D6, 32},
    {0x00D8, 0x00DE, 32},
    {0x0100, 0x0100, 1},
    {0x0102, 0x0102, 1},
    {0x0104, 0x0104, 1},
    {0x0106, 0x0106, 1},
    {0x0108, 0x0108, 1},
    {0x010A, 0x010A, 1},
    {0x010C, 0x010C, 1},
    {0x010E, 0x010E, 1},
    {0x0110, 0x0110, 1},
    {0x0112, 0x0112, 1},
    {0x0114, 0x0114, 1},
    {0x0116, 0x0116, 1},
    {0x0118, 0x0118, 1},
    {0x011A, 0x011A, 1},
    {0x011C, 0x011C, 1},
    {0x011E, 0x011E, 1},
    {0x0120, 0x0120, 1},
    {0x0122, 0x0122, 1},
    {0x0124, 0x0124, 1},
    {0x0126, 0x0126, 1},
    {0x0128, 0x0128, 1},
    {0x012A, 0x012A, 1},
    {0x012C, 0x012C, 1},
    {0x012E, 0x012E, 1},
    {0x0132, 0x0132, 1},
    {0x0134, 0x0134, 1},
    {0x0136, 0x0136, 1},
    {0x0139, 0x0139, 1},
    {0x013B, 0x013B, 1},
    {0x013D, 0x013D, 1},
    {0x013F, 0x013F, 1},
    {0x0141, 0x0141, 1},
    {0x0143, 0x0143, 1},
    {0x0145, 0x0145, 1},
    {0x0147, 0x0147, 1},
    {0x014A, 0x014A, 1},
    {0x014C, 0x014C, 1},
    {0x014E, 0x014E, 1},
    {0x0150, 0x0150, 1},
    {0x0152, 0x0152, 1},
    {0x0154, 0x0154, 1},
    {0x0156, 0x0156, 1},
    {0x0158, 0x0158, 1},
    {0x015A, 0x015A, 1},
    {0x015C, 0x015C, 1},
    {0x015E, 0x015E, 1},
    {0x0160, 0x0160, 1},
    {0x0162, 0x0162, 1},
    {0x0164, 0x0164, 1},
    {0x0166, 0x0166, 1},
    {0x0168, 0x0168, 1},
    {0x016A, 0x016A, 1},
    {0x016C, 0x016C, 1},
    {0x016E, 0x016E, 1},
    {0x0170, 0x0170, 1},
    {0x0172, 0x0172, 1},
    {0x0174, 0x0174, 1},
    {0x0176, 0x0176, 1},
    {0x0178, 0x0178, -121},
    {0x0179, 0x0179, 1},
    {0x017B, 0x017B, 1},
    {0x017D, 0x017D, 1},
    {0x0181, 0x0181, 210},
    {0x0182, 0x0182, 1},
    {0x0184, 0x0184, 1},
    {0x0186, 0x0186, 206},
    {0x0187, 0x0187, 1},
    {0x0189, 0x018A, 205},
    {0x018B, 0x018B, 1},
    {0x018E, 0x018E, 79},
    {0x018F, 0x018F, 202},
    {0x0190, 0x0190, 203},
    {0x0191, 0x0191, 1},
    {0x0193, 0x0193, 205},
    {0x0194, 0x0194, 207},
    {0x0196, 0x0196, 211},
    {0x0197, 0x0197, 209},
    {0x0198, 0x0198, 1},
    {0x019C, 0x019C, 211},
    {0x019D, 0x019D, 213},
    {0x019F, 0x019F, 214},
    {0x01A0, 0x01A0, 1},
    {0x01A2, 0x01A2, 1},
    {0x01A4, 0x01A4, 1},
    {0x01A6, 0x01A6, 218},
    {0x01A7, 0x01A7, 1},
    {0x01A9, 0x01A9, 218},
    {0x01AC, 0x01AC, 1},
    {0x01AE, 0x01AE, 218},
    {0x01AF, 0x01AF, 1},
    {0x01B1, 0x01B2, 217},
    {0x01B3, 0x01B3, 1},
    {0x01B5, 0x01B5, 1},
    {0x01B7, 0x01B7, 219},
    {0x01B8, 0x01B8, 1},
    {0x01BC, 0x01BC, 1},
    {0x01C4, 0x01C4, 2},
    {0x01C5, 0x01C5, 1},
    {0x01C7, 0x01C7, 2},
    {0x01C8, 0x01C8, 1},
    {0x01CA, 0x01CA, 2},
    {0x01CB, 0x01CB, 1},
    {0x01CD, 0x01CD, 1},
    {0x01CF, 0x01CF, 1},
    {0x01D1, 0x01D1, 1},
    {0x01D3, 0x01D3, 1},
    {0x01D5, 0x01D5, 1},
    {0x01D7, 0x01D7, 1},
    {0x01D9, 0x01D9, 1},
    {0x01DB, 0x01DB, 1},
    {0x01DE, 0x01DE, 1},
    {0x01E0, 0x01E0, 1},
    {0x01E2, 0x01E2, 1},
    {0x01E4, 0x01E4, 1},
    {0x01E6, 0x01E6, 1},
    {0x01E8, 0x01E8, 1},
    {0x01EA, 0x01EA, 1},
    {0x01EC, 0x01EC, 1},
    {0x01EE, 0x01EE, 1},
    {0x01F1, 0x01F1, 2},
    {0x01F2, 0x01F2, 1},
    {0x01F4, 0x01F4, 1},
    {0x01F6, 0x01F6, -97},
    {0x01F7, 0x01F7, -56},
    {0x01F8, 0x01F8, 1},
    {0x01FA, 0x01FA, 1},
    {0x01FC, 0x01FC, 1},
    {0x01FE, 0x01FE, 1},
    {0x0200, 0x0200, 1},
    {0x0202, 0x0202, 1},
    {0x0204, 0x0204, 1},
    {0x0206, 0x0206, 1},
    {0x0208, 0x0208, 1},
    {0x020A, 0x020A, 1},
    {0x020C, 0x020C, 1},
    {0x020E, 0x020E, 1},
    {0x0210, 0x0210, 1},
    {0x0212, 0x0212, 1},
    {0x0214, 0x0214, 1},
    {0x0216, 0x0216, 1},
    {0x0218, 0x0218, 1},
    {0x021A, 0x021A, 1},
    {0x021C, 0x021C, 1},
    {0x021E, 0x021E, 1},
    {0x0220, 0x0220, -130},
    {0x0222, 0x0222, 1},
    {0x0224, 0x0224, 1},
    {0x0226, 0x0226, 1},
    {0x0228, 0x0228, 1},
    {0x022A, 0x022A, 1},
    {0x022C, 0x022C, 1},
    {0x022E, 0x022E, 1},
    {0x0230, 0x0230, 1},
    {0x0232, 0x0232, 1},
    {0x023A, 0x023A, 10795},
    {0x023B, 0x023B, 1},
    {0x023D, 0x023D, -163},
    {0x023E, 0x023E, 10792},
    {0x0241, 0x0241, 1},
    {0x0243, 0x0243, -195},
    {0x0244, 0x0244, 69},
    {0x0245, 0x0245, 71},
    {0x0246, 0x0246, 1},
    {0x0248, 0x0248, 1},
    {0x024A, 0x024A, 1},
    {0x024C, 0x024C, 1},
    {0x024E, 0x024E, 1},
    {0x0370, 0x0370, 1},
    {0x0372, 0x0372, 1},
    {0x0376, 0x0376, 1},
    {0x037F, 0x037F, 116},
    {0x0386, 0x0386, 38},
    {0x0388, 0x038A, 37},
    {0x038C, 0x038C, 64},
    {0x038E, 0x038F, 63},
    {0x0391, 0x03A1, 32},
    {0x03A3, 0x03AB, 32},
    {0x03CF, 0x03CF, 8},
    {0x03D8, 0x03D8, 1},
    {0x03DA, 0x03DA, 1},
    {0x03DC, 0x03DC, 1},
    {0x03DE, 0x03DE, 1},
    {0x03E0, 0x03E0, 1},
    {0x03E2, 0x03E2, 1},
    {0x03E4, 0x03E4, 1},
    {0x03E6, 0x03E6, 1},
    {0x03E8, 0x03E8, 1},
    {0x03EA, 0x03EA, 1},
    {0x03EC, 0x03EC, 1},
    {0x03EE, 0x03EE, 1},
    {0x03F4, 0x03F4, -60},
    {0x03F7, 0x03F7, 1},
    {0x03F9, 0x03F9, -7},
    {0x03FA, 0x03FA, 1},
    {0x03FD, 0x03FF, -130},
    {0x0400, 0x040F, 80},
    {0x0410, 0x042F, 32},
    {0x0460, 0x0460, 1},
    {0x0462, 0x0462, 1},
    {0x0464, 0x0464, 1},
    {0x0466, 0x0466, 1},
    {0x0468, 0x0468, 1},
    {0x046A, 0x046A, 1},
    {0x046C, 0x046C, 1},
    {0x046E, 0x046E, 1},
    {0x0470, 0x0470, 1},
    {0x0472, 0x0472, 1},
    {0x0474, 0x0474, 1},
    {0x0476, 0x0476, 1},
    {0x0478, 0x0478, 1},
    {0x047A, 0x047A, 1},
    {0x047C, 0x047C, 1},
    {0x047E, 0x047E, 1},
    {0x0480, 0x0480, 1},
    {0x048A, 0x048A, 1},
    {0x048C, 0x048C, 1},
    {0x048E, 0x048E, 1},
    {0x0490, 0x0490, 1},
    {0x0492, 0x0492, 1},
    {0x0494, 0x0494, 1},
    {0x0496, 0x0496, 1},
    {0x0498, 0x0498, 1},
    {0x049A, 0x049A, 1},
    {0x049C, 0x049C, 1},
    {0x049E, 0x049E, 1},
    {0x04A0, 0x04A0, 1},
    {0x04A2, 0x04A2, 1},
    {0x04A4, 0x04A4, 1},
    {0x04A6, 0x04A6, 1},
    {0x04A8, 0x04A8, 1},
    {0x04AA, 0x04AA, 1},
    {0x04AC, 0x04AC, 1},
    {0x04AE, 0x04AE, 1},
    {0x04B0, 0x04B0, 1},
    {0x04B2, 0x04B2, 1},
    {0x04B4, 0x04B4, 1},
    {0x04B6, 0x04B6, 1},
    {0x04B8, 0x04B8, 1},
    {0x04BA, 0x04BA, 1},
    {0x04BC, 0x04BC, 1},
    {0x04BE, 0x04BE, 1},
    {0x04C0, 0x04C0, 15},
    {0x04C1, 0x04C1, 1},
    {0x04C3, 0x04C3, 1},
    {0x04C5, 0x04C5, 1},
    {0x04C7, 0x04C7, 1},
    {0x04C9, 0x04C9, 1},
    {0x04CB, 0x04CB, 1},
    {0x04CD, 0x04CD, 1},
    {0x04D0, 0x04D0, 1},
    {0x04D2, 0x04D2, 1},
    {0x04D4, 0x04D4, 1},
    {0x04D6, 0x04D6, 1},
    {0x04D8, 0x04D8, 1},
    {0x04DA, 0x04DA, 1},
    {0x04DC, 0x04DC, 1},
    {0x04DE, 0x04DE, 1},
    {0x04E0, 0x04E0, 1},
    {0x04E2, 0x04E2, 1},
    {0x04E4, 0x04E4, 1},
    {0x04E6, 0x04E6, 1},
    {0x04E8, 0x04E8, 1},
    {0x04EA, 0x04EA, 1},
    {0x04EC, 0x04EC, 1},
    {0x04EE, 0x04EE, 1},
    {0x04F0, 0x04F0, 1},
    {0x04F2, 0x04F2, 1},
    {0x04F4, 0x04F4, 1},
    {0x04F6, 0x04F6, 1},
    {0x04F8, 0x04F8, 1},
    {0x04FA, 0x04FA, 1},
    {0x04FC, 0x04FC, 1},
    {0x04FE, 0x04FE, 1},
    {0x0500, 0x0500, 1},
    {0x0502, 0x0502, 1},
    {0x0504, 0x0504, 1},
    {0x0506, 0x0506, 1},
    {0x0508, 0x0508, 1},
    {0x050A, 0x050A, 1},
    {0x050C, 0x050C, 1},
    {0x050E, 0x050E, 1},
    {0x0510, 0x0510, 1},
    {0x0512, 0x0512, 1},
    {0x0514, 0x0514, 1},
    {0x0516, 0x0516, 1},
    {0x0518, 0x0518, 1},
    {0x051A, 0x051A, 1},
    {0x051C, 0x051C, 1},
    {0x051E, 0x051E, 1},
    {0x0520, 0x0520, 1},
    {0x0522, 0x0522, 1},
    {0x0524, 0x0524, 1},
    {0x0526, 0x0526, 1},
    {0x0528, 0x0528, 1},
    {0x052A, 0x052A, 1},
    {0x052C, 0x052C, 1},
    {0x052E, 0x052E, 1},
    {0x0531, 0x0556, 48},
    {0x10A0, 0x10C5, 7264},
    {0x10C7, 0x10C7, 7264},
    {0x10CD, 0x10CD, 7264},
    {0x13A0, 0x13EF, 38864},
    {0x13F0, 0x13F5, 8},
    {0x1C89, 0x1C89, 1},
    {0x1C90, 0x1CBA, -3008},
    {0x1CBD, 0x1CBF, -3008},
    {0x1E00, 0x1E00, 1},
    {0x1E02, 0x1E02, 1},
    {0x1E04, 0x1E04, 1},
    {0x1E06, 0x1E06, 1},
    {0x1E08, 0x1E08, 1},
    {0x1E0A, 0x1E0A, 1},
    {0x1E0C, 0x1E0C, 1},
    {0x1E0E, 0x1E0E, 1},
    {0x1E10, 0x1E10, 1},
    {0x1E12, 0x1E12, 1},
    {0x1E14, 0x1E14, 1},
    {0x1E16, 0x1E16, 1},
    {0x1E18, 0x1E18, 1},
    {0x1E1A, 0x1E1A, 1},
    {0x1E1C, 0x1E1C, 1},
    {0x1E1E, 0x1E1E, 1},
    {0x1E20, 0x1E20, 1},
    {0x1E22, 0x1E22, 1},
    {0x1E24, 0x1E24, 1},
    {0x1E26, 0x1E26, 1},
    {0x1E28, 0x1E28, 1},
    {0x1E2A, 0x1E2A, 1},
    {0x1E2C, 0x1E2C, 1},
    {0x1E2E, 0x1E2E, 1},
    {0x1E30, 0x1E30, 1},
    {0x1E32, 0x1E32, 1},
    {0x1E34, 0x1E34, 1},
    {0x1E36, 0x1E36, 1},
    {0x1E38, 0x1E38, 1},
    {0x1E3A, 0x1E3A, 1},
    {0x1E3C, 0x1E3C, 1},
    {0x1E3E, 0x1E3E, 1},
    {0x1E40, 0x1E40, 1},
    {0x1E42, 0x1E42, 1},
    {0x1E44, 0x1E44, 1},
    {0x1E46, 0x1E46, 1},
    {0x1E48, 0x1E48, 1},
    {0x1E4A, 0x1E4A, 1},
    {0x1E4C, 0x1E4C, 1},
    {0x1E4E, 0x1E4E, 1},
    {0x1E50, 0x1E50, 1},
    {0x1E52, 0x1E52, 1},
    {0x1E54, 0x1E54, 1},
    {0x1E56, 0x1E56, 1},
    {0x1E58, 0x1E58, 1},
    {0x1E5A, 0x1E5A, 1},
    {0x1E5C, 0x1E5C, 1},
    {0x1E5E, 0x1E5E, 1},
    {0x1E60, 0x1E60, 1},
    {0x1E62, 0x1E62, 1},
    {0x1E64, 0x1E64, 1},
    {0x1E66, 0x1E66, 1},
    {0x1E68, 0x1E68, 1},
    {0x1E6A, 0x1E6A, 1},
    {0x1E6C, 0x1E6C, 1},
    {0x1E6E, 0x1E6E, 1},
    {0x1E70, 0x1E70, 1},
    {0x1E72, 0x1E72, 1},
    {0x1E74, 0x1E74, 1},
    {0x1E76, 0x1E76, 1},
    {0x1E78, 0x1E78, 1},
    {0x1E7A, 0x1E7A, 1},
    {0x1E7C, 0x1E7C, 1},
    {0x1E7E, 0x1E7E, 1},
    {0x1E80, 0x1E80, 1},
    {0x1E82, 0x1E82, 1},
    {0x1E84, 0x1E84, 1},
    {0x1E86, 0x1E86, 1},
    {0x1E88, 0x1E88, 1},
    {0x1E8A, 0x1E8A, 1},
    {0x1E8C, 0x1E8C, 1},
    {0x1E8E, 0x1E8E, 1},
    {0x1E90, 0x1E90, 1},
    {0x1E92, 0x1E92, 1},
    {0x1E94, 0x1E94, 1},
    {0x1E9E, 0x1E9E, -7615},
    {0x1EA0, 0x1EA0, 1},
    {0x1EA2, 0x1EA2, 1},
    {0x1EA4, 0x1EA4, 1},
    {0x1EA6, 0x1EA6, 1},
    {0x1EA8, 0x1EA8, 1},
    {0x1EAA, 0x1EAA, 1},
    {0x1EAC, 0x1EAC, 1},
    {0x1EAE, 0x1EAE, 1},
    {0x1EB0, 0x1EB0, 1},
    {0x1EB2, 0x1EB2, 1},
    {0x1EB4, 0x1EB4, 1},
    {0x1EB6, 0x1EB6, 1},
    {0x1EB8, 0x1EB8, 1},
    {0x1EBA, 0x1EBA, 1},
    {0x1EBC, 0x1EBC, 1},
    {0x1EBE, 0x1EBE, 1},
    {0x1EC0, 0x1EC0, 1},
    {0x1EC2, 0x1EC2, 1},
    {0x1EC4, 0x1EC4, 1},
    {0x1EC6, 0x1EC6, 1},
    {0x1EC8, 0x1EC8, 1},
    {0x1ECA, 0x1ECA, 1},
    {0x1ECC, 0x1ECC, 1},
    {0x1ECE, 0x1ECE, 1},
    {0x1ED0, 0x1ED0, 1},
    {0x1ED2, 0x1ED2, 1},
    {0x1ED4, 0x1ED4, 1},
    {0x1ED6, 0x1ED6, 1},
    {0x1ED8, 0x1ED8, 1},
    {0x1EDA, 0x1EDA, 1},
    {0x1EDC, 0x1EDC, 1},
    {0x1EDE, 0x1EDE, 1},
    {0x1EE0, 0x1EE0, 1},
    {0x1EE2, 0x1EE2, 1},
    {0x1EE4, 0x1EE4, 1},
    {0x1EE6, 0x1EE6, 1},
    {0x1EE8, 0x1EE8, 1},
    {0x1EEA, 0x1EEA, 1},
    {0x1EEC, 0x1EEC, 1},
    {0x1EEE, 0x1EEE, 1},
    {0x1EF0, 0x1EF0, 1},
    {0x1EF2, 0x1EF2, 1},
    {0x1EF4, 0x1EF4, 1},
    {0x1EF6, 0x1EF6, 1},
    {0x1EF8, 0x1EF8, 1},
    {0x1EFA, 0x1EFA, 1},
    {0x1EFC, 0x1EFC, 1},
    {0x1EFE, 0x1EFE, 1},
    {0x1F08, 0x1F0F, -8},
    {0x1F18, 0x1F1D, -8},
    {0x1F28, 0x1F2F, -8},
    {0x1F38, 0x1F3F, -8},
    {0x1F48, 0x1F4D, -8},
    {0x1F59, 0x1F59, -8},
    {0x1F5B, 0x1F5B, -8},
    {0x1F5D, 0x1F5D, -8},
    {0x1F5F, 0x1F5F, -8},
    {0x1F68, 0x1F6F, -8},
    {0x1F88, 0x1F8F, -8},
    {0x1F98, 0x1F9F, -8},
    {0x1FA8, 0x1FAF, -8},
    {0x1FB8, 0x1FB9, -8},
    {0x1FBA, 0x1FBB, -74},
    {0x1FBC, 0x1FBC, -9},
    {0x1FC8, 0x1FCB, -86},
    {0x1FCC, 0x1FCC, -9},
    {0x1FD8, 0x1FD9, -8},
    {0x1FDA, 0x1FDB, -100},
    {0x1FE8, 0x1FE9, -8},
    {0x1FEA, 0x1FEB, -112},
    {0x1FEC, 0x1FEC, -7},
    {0x1FF8, 0x1FF9, -128},
    {0x1FFA, 0x1FFB, -126},
    {0x1FFC, 0x1FFC, -9},
    {0x2126, 0x2126, -7517},
    {0x212A, 0x212A, -8383},
    {0x212B, 0x212B, -8262},
    {0x2132, 0x2132, 28},
    {0x2160, 0x216F, 16},
    {0x2183, 0x2183, 1},
    {0x24B6, 0x24CF, 26},
    {0x2C00, 0x2C2F, 48},
    {0x2C60, 0x2C60, 1},
    {0x2C62, 0x2C62, -10743},
    {0x2C63, 0x2C63, -3814},
    {0x2C64, 0x2C64, -10727},
    {0x2C67, 0x2C67, 1},
    {0x2C69, 0x2C69, 1},
    {0x2C6B, 0x2C6B, 1},
    {0x2C6D, 0x2C6D, -10780},
    {0x2C6E, 0x2C6E, -10749},
    {0x2C6F, 0x2C6F, -10783},
    {0x2C70, 0x2C70, -10782},
    {0x2C72, 0x2C72, 1},
    {0x2C75, 0x2C75, 1},
    {0x2C7E, 0x2C7F, -10815},
    {0x2C80, 0x2C80, 1},
    {0x2C82, 0x2C82, 1},
    {0x2C84, 0x2C84, 1},
    {0x2C86, 0x2C86, 1},
    {0x2C88, 0x2C88, 1},
    {0x2C8A, 0x2C8A, 1},
    {0x2C8C, 0x2C8C, 1},
    {0x2C8E, 0x2C8E, 1},
    {0x2C90, 0x2C90, 1},
    {0x2C92, 0x2C92, 1},
    {0x2C94, 0x2C94, 1},
    {0x2C96, 0x2C96, 1},
    {0x2C98, 0x2C98, 1},
    {0x2C9A, 0x2C9A, 1},
    {0x2C9C, 0x2C9C, 1},
    {0x2C9E, 0x2C9E, 1},
    {0x2CA0, 0x2CA0, 1},
    {0x2CA2, 0x2CA2, 1},
    {0x2CA4, 0x2CA4, 1},
    {0x2CA6, 0x2CA6, 1},
    {0x2CA8, 0x2CA8, 1},
    {0x2CAA, 0x2CAA, 1},
    {0x2CAC, 0x2CAC, 1},
    {0x2CAE, 0x2CAE, 1},
    {0x2CB0, 0x2CB0, 1},
    {0x2CB2, 0x2CB2, 1},
    {0x2CB4, 0x2CB4, 1},
    {0x2CB6, 0x2CB6, 1},
    {0x2CB8, 0x2CB8, 1},
    {0x2CBA, 0x2CBA, 1},
    {0x2CBC, 0x2CBC, 1},
    {0x2CBE, 0x2CBE, 1},
    {0x2CC0, 0x2CC0, 1},
    {0x2CC2, 0x2CC2, 1},
    {0x2CC4, 0x2CC4, 1},
    {0x2CC6, 0x2CC6, 1},
    {0x2CC8, 0x2CC8, 1},
    {0x2CCA, 0x2CCA, 1},
    {0x2CCC, 0x2CCC, 1},
    {0x2CCE, 0x2CCE, 1},
    {0x2CD0, 0x2CD0, 1},
    {0x2CD2, 0x2CD2, 1},
    {0x2CD4, 0x2CD4, 1},
    {0x2CD6, 0x2CD6, 1},
    {0x2CD8, 0x2CD8, 1},
    {0x2CDA, 0x2CDA, 1},
    {0x2CDC, 0x2CDC, 1},
    {0x2CDE, 0x2CDE, 1},
    {0x2CE0, 0x2CE0, 1},
    {0x2CE2, 0x2CE2, 1},
    {0x2CEB, 0x2CEB, 1},
    {0x2CED, 0x2CED, 1},
    {0x2CF2, 0x2CF2, 1},
    {0xA640, 0xA640, 1},
    {0xA642, 0xA642, 1},
    {0xA644, 0xA644, 1},
    {0xA646, 0xA646, 1},
    {0xA648, 0xA648, 1},
    {0xA64A, 0xA64A, 1},
    {0xA64C, 0xA64C, 1},
    {0xA64E, 0xA64E, 1},
    {0xA650, 0xA650, 1},
    {0xA652, 0xA652, 1},
    {0xA654, 0xA654, 1},
    {0xA656, 0xA656, 1},
    {0xA658, 0xA658, 1},
    {0xA65A, 0xA65A, 1},
    {0xA65C, 0xA65C, 1},
    {0xA65E, 0xA65E, 1},
    {0xA660, 0xA660, 1},
    {0xA662, 0xA662, 1},
    {0xA664, 0xA664, 1},
    {0xA666, 0xA666, 1},
    {0xA668, 0xA668, 1},
    {0xA66A, 0xA66A, 1},
    {0xA66C, 0xA66C, 1},
    {0xA680, 0xA680, 1},
    {0xA682, 0xA682, 1},
    {0xA684, 0xA684, 1},
    {0xA686, 0xA686, 1},
    {0xA688, 0xA688, 1},
    {0xA68A, 0xA68A, 1},
    {0xA68C, 0xA68C, 1},
    {0xA68E, 0xA68E, 1},
    {0xA690, 0xA690, 1},
    {0xA692, 0xA692, 1},
    {0xA694, 0xA694, 1},
    {0xA696, 0xA696, 1},
    {0xA698, 0xA698, 1},
    {0xA69A, 0xA69A, 1},
    {0xA722, 0xA722, 1},
    {0xA724, 0xA724, 1},
    {0xA726, 0xA726, 1},
    {0xA728, 0xA728, 1},
    {0xA72A, 0xA72A, 1},
    {0xA72C, 0xA72C, 1},
    {0xA72E, 0xA72E, 1},
    {0xA732, 0xA732, 1},
    {0xA734, 0xA734, 1},
    {0xA736, 0xA736, 1},
    {0xA738, 0xA738, 1},
    {0xA73A, 0xA73A, 1},
    {0xA73C, 0xA73C, 1},
    {0xA73E, 0xA73E, 1},
    {0xA740, 0xA740, 1},
    {0xA742, 0xA742, 1},
    {0xA744, 0xA744, 1},
    {0xA746, 0xA746, 1},
    {0xA748, 0xA748, 1},
    {0xA74A, 0xA74A, 1},
    {0xA74C, 0xA74C, 1},
    {0xA74E, 0xA74E, 1},
    {0xA750, 0xA750, 1},
    {0xA752, 0xA752, 1},
    {0xA754, 0xA754, 1},
    {0xA756, 0xA756, 1},
    {0xA758, 0xA758, 1},
    {0xA75A, 0xA75A, 1},
    {0xA75C, 0xA75C, 1},
    {0xA75E, 0xA75E, 1},
    {0xA760, 0xA760, 1},
    {0xA762, 0xA762, 1},
    {0xA764, 0xA764, 1},
    {0xA766, 0xA766, 1},
    {0xA768, 0xA768, 1},
    {0xA76A, 0xA76A, 1},
    {0xA76C, 0xA76C, 1},
    {0xA76E, 0xA76E, 1},
    {0xA779, 0xA779, 1},
    {0xA77B, 0xA77B, 1},
    {0xA77D, 0xA77D, -35332},
    {0xA77E, 0xA77E, 1},
    {0xA780, 0xA780, 1},
    {0xA782, 0xA782, 1},
    {0xA784, 0xA784, 1},
    {0xA786, 0xA786, 1},
    {0xA78B, 0xA78B, 1},
    {0xA78D, 0xA78D, -42280},
    {0xA790, 0xA790, 1},
    {0xA792, 0xA792, 1},
    {0xA796, 0xA796, 1},
    {0xA798, 0xA798, 1},
    {0xA79A, 0xA79A, 1},
    {0xA79C, 0xA79C, 1},
    {0xA79E, 0xA79E, 1},
    {0xA7A0, 0xA7A0, 1},
    {0xA7A2, 0xA7A2, 1},
    {0xA7A4, 0xA7A4, 1},
    {0xA7A6, 0xA7A6, 1},
    {0xA7A8, 0xA7A8, 1},
    {0xA7AA, 0xA7AA, -42308},
    {0xA7AB, 0xA7AB, -42319},
    {0xA7AC, 0xA7AC, -42315},
    {0xA7AD, 0xA7AD, -42305},
    {0xA7AE, 0xA7AE, -42308},
    {0xA7B0, 0xA7B0, -42258},
    {0xA7B1, 0xA7B1, -42282},
    {0xA7B2, 0xA7B2, -42261},
    {0xA7B3, 0xA7B3, 928},
    {0xA7B4, 0xA7B4, 1},
    {0xA7B6, 0xA7B6, 1},
    {0xA7B8, 0xA7B8, 1},
    {0xA7BA, 0xA7BA, 1},
    {0xA7BC, 0xA7BC, 1},
    {0xA7BE, 0xA7BE, 1},
    {0xA7C0, 0xA7C0, 1},
    {0xA7C2, 0xA7C2, 1},
    {0xA7C4, 0xA7C4, -48},
    {0xA7C5, 0xA7C5, -42307},
    {0xA7C6, 0xA7C6, -35384},
    {0xA7C7, 0xA7C7, 1},
    {0xA7C9, 0xA7C9, 1},
    {0xA7CB, 0xA7CB, -42343},
    {0xA7CC, 0xA7CC, 1},
    {0xA7D0, 0xA7D0, 1},
    {0xA7D6, 0xA7D6, 1},
    {0xA7D8, 0xA7D8, 1},
    {0xA7DA, 0xA7DA, 1},
    {0xA7DC, 0xA7DC, -42561},
    {0xA7F5, 0xA7F5, 1},
    {0xFF21, 0xFF3A, 32},
    {0x10400, 0x10427, 40},
    {0x104B0, 0x104D3, 40},
    {0x10570, 0x1057A, 39},
    {0x1057C, 0x1058A, 39},
    {0x1058C, 0x10592, 39},
    {0x10594, 0x10595, 39},
    {0x10C80, 0x10CB2, 64},
    {0x10D50, 0x10D65, 32},
    {0x118A0, 0x118BF, 32},
    {0x16E40, 0x16E5F, 32},
    {0x1E900, 0x1E921, 34},
};

static const blorp_unicode_case_special blorp_lower_specials[] = {
    {0x0130, 2, {0x0069, 0x0307, 0x0000}},
};

static const blorp_unicode_case_range blorp_cased_ranges[] = {
    {0x0041, 0x005A, 0},
    {0x0061, 0x007A, 0},
    {0x00AA, 0x00AA, 0},
    {0x00B5, 0x00B5, 0},
    {0x00BA, 0x00BA, 0},
    {0x00C0, 0x00D6, 0},
    {0x00D8, 0x00F6, 0},
    {0x00F8, 0x01BA, 0},
    {0x01BC, 0x01BF, 0},
    {0x01C4, 0x0293, 0},
    {0x0295, 0x02AF, 0},
    {0x02B0, 0x02B8, 0},
    {0x02C0, 0x02C1, 0},
    {0x02E0, 0x02E4, 0},
    {0x0345, 0x0345, 0},
    {0x0370, 0x0373, 0},
    {0x0376, 0x0377, 0},
    {0x037A, 0x037A, 0},
    {0x037B, 0x037D, 0},
    {0x037F, 0x037F, 0},
    {0x0386, 0x0386, 0},
    {0x0388, 0x038A, 0},
    {0x038C, 0x038C, 0},
    {0x038E, 0x03A1, 0},
    {0x03A3, 0x03F5, 0},
    {0x03F7, 0x0481, 0},
    {0x048A, 0x052F, 0},
    {0x0531, 0x0556, 0},
    {0x0560, 0x0588, 0},
    {0x10A0, 0x10C5, 0},
    {0x10C7, 0x10C7, 0},
    {0x10CD, 0x10CD, 0},
    {0x10D0, 0x10FA, 0},
    {0x10FC, 0x10FC, 0},
    {0x10FD, 0x10FF, 0},
    {0x13A0, 0x13F5, 0},
    {0x13F8, 0x13FD, 0},
    {0x1C80, 0x1C8A, 0},
    {0x1C90, 0x1CBA, 0},
    {0x1CBD, 0x1CBF, 0},
    {0x1D00, 0x1D2B, 0},
    {0x1D2C, 0x1D6A, 0},
    {0x1D6B, 0x1D77, 0},
    {0x1D78, 0x1D78, 0},
    {0x1D79, 0x1D9A, 0},
    {0x1D9B, 0x1DBF, 0},
    {0x1E00, 0x1F15, 0},
    {0x1F18, 0x1F1D, 0},
    {0x1F20, 0x1F45, 0},
    {0x1F48, 0x1F4D, 0},
    {0x1F50, 0x1F57, 0},
    {0x1F59, 0x1F59, 0},
    {0x1F5B, 0x1F5B, 0},
    {0x1F5D, 0x1F5D, 0},
    {0x1F5F, 0x1F7D, 0},
    {0x1F80, 0x1FB4, 0},
    {0x1FB6, 0x1FBC, 0},
    {0x1FBE, 0x1FBE, 0},
    {0x1FC2, 0x1FC4, 0},
    {0x1FC6, 0x1FCC, 0},
    {0x1FD0, 0x1FD3, 0},
    {0x1FD6, 0x1FDB, 0},
    {0x1FE0, 0x1FEC, 0},
    {0x1FF2, 0x1FF4, 0},
    {0x1FF6, 0x1FFC, 0},
    {0x2071, 0x2071, 0},
    {0x207F, 0x207F, 0},
    {0x2090, 0x209C, 0},
    {0x2102, 0x2102, 0},
    {0x2107, 0x2107, 0},
    {0x210A, 0x2113, 0},
    {0x2115, 0x2115, 0},
    {0x2119, 0x211D, 0},
    {0x2124, 0x2124, 0},
    {0x2126, 0x2126, 0},
    {0x2128, 0x2128, 0},
    {0x212A, 0x212D, 0},
    {0x212F, 0x2134, 0},
    {0x2139, 0x2139, 0},
    {0x213C, 0x213F, 0},
    {0x2145, 0x2149, 0},
    {0x214E, 0x214E, 0},
    {0x2160, 0x217F, 0},
    {0x2183, 0x2184, 0},
    {0x24B6, 0x24E9, 0},
    {0x2C00, 0x2C7B, 0},
    {0x2C7C, 0x2C7D, 0},
    {0x2C7E, 0x2CE4, 0},
    {0x2CEB, 0x2CEE, 0},
    {0x2CF2, 0x2CF3, 0},
    {0x2D00, 0x2D25, 0},
    {0x2D27, 0x2D27, 0},
    {0x2D2D, 0x2D2D, 0},
    {0xA640, 0xA66D, 0},
    {0xA680, 0xA69B, 0},
    {0xA69C, 0xA69D, 0},
    {0xA722, 0xA76F, 0},
    {0xA770, 0xA770, 0},
    {0xA771, 0xA787, 0},
    {0xA78B, 0xA78E, 0},
    {0xA790, 0xA7CD, 0},
    {0xA7D0, 0xA7D1, 0},
    {0xA7D3, 0xA7D3, 0},
    {0xA7D5, 0xA7DC, 0},
    {0xA7F2, 0xA7F4, 0},
    {0xA7F5, 0xA7F6, 0},
    {0xA7F8, 0xA7F9, 0},
    {0xA7FA, 0xA7FA, 0},
    {0xAB30, 0xAB5A, 0},
    {0xAB5C, 0xAB5F, 0},
    {0xAB60, 0xAB68, 0},
    {0xAB69, 0xAB69, 0},
    {0xAB70, 0xABBF, 0},
    {0xFB00, 0xFB06, 0},
    {0xFB13, 0xFB17, 0},
    {0xFF21, 0xFF3A, 0},
    {0xFF41, 0xFF5A, 0},
    {0x10400, 0x1044F, 0},
    {0x104B0, 0x104D3, 0},
    {0x104D8, 0x104FB, 0},
    {0x10570, 0x1057A, 0},
    {0x1057C, 0x1058A, 0},
    {0x1058C, 0x10592, 0},
    {0x10594, 0x10595, 0},
    {0x10597, 0x105A1, 0},
    {0x105A3, 0x105B1, 0},
    {0x105B3, 0x105B9, 0},
    {0x105BB, 0x105BC, 0},
    {0x10780, 0x10780, 0},
    {0x10783, 0x10785, 0},
    {0x10787, 0x107B0, 0},
    {0x107B2, 0x107BA, 0},
    {0x10C80, 0x10CB2, 0},
    {0x10CC0, 0x10CF2, 0},
    {0x10D50, 0x10D65, 0},
    {0x10D70, 0x10D85, 0},
    {0x118A0, 0x118DF, 0},
    {0x16E40, 0x16E7F, 0},
    {0x1D400, 0x1D454, 0},
    {0x1D456, 0x1D49C, 0},
    {0x1D49E, 0x1D49F, 0},
    {0x1D4A2, 0x1D4A2, 0},
    {0x1D4A5, 0x1D4A6, 0},
    {0x1D4A9, 0x1D4AC, 0},
    {0x1D4AE, 0x1D4B9, 0},
    {0x1D4BB, 0x1D4BB, 0},
    {0x1D4BD, 0x1D4C3, 0},
    {0x1D4C5, 0x1D505, 0},
    {0x1D507, 0x1D50A, 0},
    {0x1D50D, 0x1D514, 0},
    {0x1D516, 0x1D51C, 0},
    {0x1D51E, 0x1D539, 0},
    {0x1D53B, 0x1D53E, 0},
    {0x1D540, 0x1D544, 0},
    {0x1D546, 0x1D546, 0},
    {0x1D54A, 0x1D550, 0},
    {0x1D552, 0x1D6A5, 0},
    {0x1D6A8, 0x1D6C0, 0},
    {0x1D6C2, 0x1D6DA, 0},
    {0x1D6DC, 0x1D6FA, 0},
    {0x1D6FC, 0x1D714, 0},
    {0x1D716, 0x1D734, 0},
    {0x1D736, 0x1D74E, 0},
    {0x1D750, 0x1D76E, 0},
    {0x1D770, 0x1D788, 0},
    {0x1D78A, 0x1D7A8, 0},
    {0x1D7AA, 0x1D7C2, 0},
    {0x1D7C4, 0x1D7CB, 0},
    {0x1DF00, 0x1DF09, 0},
    {0x1DF0B, 0x1DF1E, 0},
    {0x1DF25, 0x1DF2A, 0},
    {0x1E030, 0x1E06D, 0},
    {0x1E900, 0x1E943, 0},
    {0x1F130, 0x1F149, 0},
    {0x1F150, 0x1F169, 0},
    {0x1F170, 0x1F189, 0},
};

static const blorp_unicode_case_range blorp_case_ignorable_ranges[] = {
    {0x0027, 0x0027, 0},
    {0x002E, 0x002E, 0},
    {0x003A, 0x003A, 0},
    {0x005E, 0x005E, 0},
    {0x0060, 0x0060, 0},
    {0x00A8, 0x00A8, 0},
    {0x00AD, 0x00AD, 0},
    {0x00AF, 0x00AF, 0},
    {0x00B4, 0x00B4, 0},
    {0x00B7, 0x00B7, 0},
    {0x00B8, 0x00B8, 0},
    {0x02B0, 0x02C1, 0},
    {0x02C2, 0x02C5, 0},
    {0x02C6, 0x02D1, 0},
    {0x02D2, 0x02DF, 0},
    {0x02E0, 0x02E4, 0},
    {0x02E5, 0x02EB, 0},
    {0x02EC, 0x02EC, 0},
    {0x02ED, 0x02ED, 0},
    {0x02EE, 0x02EE, 0},
    {0x02EF, 0x02FF, 0},
    {0x0300, 0x036F, 0},
    {0x0374, 0x0374, 0},
    {0x0375, 0x0375, 0},
    {0x037A, 0x037A, 0},
    {0x0384, 0x0385, 0},
    {0x0387, 0x0387, 0},
    {0x0483, 0x0487, 0},
    {0x0488, 0x0489, 0},
    {0x0559, 0x0559, 0},
    {0x055F, 0x055F, 0},
    {0x0591, 0x05BD, 0},
    {0x05BF, 0x05BF, 0},
    {0x05C1, 0x05C2, 0},
    {0x05C4, 0x05C5, 0},
    {0x05C7, 0x05C7, 0},
    {0x05F4, 0x05F4, 0},
    {0x0600, 0x0605, 0},
    {0x0610, 0x061A, 0},
    {0x061C, 0x061C, 0},
    {0x0640, 0x0640, 0},
    {0x064B, 0x065F, 0},
    {0x0670, 0x0670, 0},
    {0x06D6, 0x06DC, 0},
    {0x06DD, 0x06DD, 0},
    {0x06DF, 0x06E4, 0},
    {0x06E5, 0x06E6, 0},
    {0x06E7, 0x06E8, 0},
    {0x06EA, 0x06ED, 0},
    {0x070F, 0x070F, 0},
    {0x0711, 0x0711, 0},
    {0x0730, 0x074A, 0},
    {0x07A6, 0x07B0, 0},
    {0x07EB, 0x07F3, 0},
    {0x07F4, 0x07F5, 0},
    {0x07FA, 0x07FA, 0},
    {0x07FD, 0x07FD, 0},
    {0x0816, 0x0819, 0},
    {0x081A, 0x081A, 0},
    {0x081B, 0x0823, 0},
    {0x0824, 0x0824, 0},
    {0x0825, 0x0827, 0},
    {0x0828, 0x0828, 0},
    {0x0829, 0x082D, 0},
    {0x0859, 0x085B, 0},
    {0x0888, 0x0888, 0},
    {0x0890, 0x0891, 0},
    {0x0897, 0x089F, 0},
    {0x08C9, 0x08C9, 0},
    {0x08CA, 0x08E1, 0},
    {0x08E2, 0x08E2, 0},
    {0x08E3, 0x0902, 0},
    {0x093A, 0x093A, 0},
    {0x093C, 0x093C, 0},
    {0x0941, 0x0948, 0},
    {0x094D, 0x094D, 0},
    {0x0951, 0x0957, 0},
    {0x0962, 0x0963, 0},
    {0x0971, 0x0971, 0},
    {0x0981, 0x0981, 0},
    {0x09BC, 0x09BC, 0},
    {0x09C1, 0x09C4, 0},
    {0x09CD, 0x09CD, 0},
    {0x09E2, 0x09E3, 0},
    {0x09FE, 0x09FE, 0},
    {0x0A01, 0x0A02, 0},
    {0x0A3C, 0x0A3C, 0},
    {0x0A41, 0x0A42, 0},
    {0x0A47, 0x0A48, 0},
    {0x0A4B, 0x0A4D, 0},
    {0x0A51, 0x0A51, 0},
    {0x0A70, 0x0A71, 0},
    {0x0A75, 0x0A75, 0},
    {0x0A81, 0x0A82, 0},
    {0x0ABC, 0x0ABC, 0},
    {0x0AC1, 0x0AC5, 0},
    {0x0AC7, 0x0AC8, 0},
    {0x0ACD, 0x0ACD, 0},
    {0x0AE2, 0x0AE3, 0},
    {0x0AFA, 0x0AFF, 0},
    {0x0B01, 0x0B01, 0},
    {0x0B3C, 0x0B3C, 0},
    {0x0B3F, 0x0B3F, 0},
    {0x0B41, 0x0B44, 0},
    {0x0B4D, 0x0B4D, 0},
    {0x0B55, 0x0B56, 0},
    {0x0B62, 0x0B63, 0},
    {0x0B82, 0x0B82, 0},
    {0x0BC0, 0x0BC0, 0},
    {0x0BCD, 0x0BCD, 0},
    {0x0C00, 0x0C00, 0},
    {0x0C04, 0x0C04, 0},
    {0x0C3C, 0x0C3C, 0},
    {0x0C3E, 0x0C40, 0},
    {0x0C46, 0x0C48, 0},
    {0x0C4A, 0x0C4D, 0},
    {0x0C55, 0x0C56, 0},
    {0x0C62, 0x0C63, 0},
    {0x0C81, 0x0C81, 0},
    {0x0CBC, 0x0CBC, 0},
    {0x0CBF, 0x0CBF, 0},
    {0x0CC6, 0x0CC6, 0},
    {0x0CCC, 0x0CCD, 0},
    {0x0CE2, 0x0CE3, 0},
    {0x0D00, 0x0D01, 0},
    {0x0D3B, 0x0D3C, 0},
    {0x0D41, 0x0D44, 0},
    {0x0D4D, 0x0D4D, 0},
    {0x0D62, 0x0D63, 0},
    {0x0D81, 0x0D81, 0},
    {0x0DCA, 0x0DCA, 0},
    {0x0DD2, 0x0DD4, 0},
    {0x0DD6, 0x0DD6, 0},
    {0x0E31, 0x0E31, 0},
    {0x0E34, 0x0E3A, 0},
    {0x0E46, 0x0E46, 0},
    {0x0E47, 0x0E4E, 0},
    {0x0EB1, 0x0EB1, 0},
    {0x0EB4, 0x0EBC, 0},
    {0x0EC6, 0x0EC6, 0},
    {0x0EC8, 0x0ECE, 0},
    {0x0F18, 0x0F19, 0},
    {0x0F35, 0x0F35, 0},
    {0x0F37, 0x0F37, 0},
    {0x0F39, 0x0F39, 0},
    {0x0F71, 0x0F7E, 0},
    {0x0F80, 0x0F84, 0},
    {0x0F86, 0x0F87, 0},
    {0x0F8D, 0x0F97, 0},
    {0x0F99, 0x0FBC, 0},
    {0x0FC6, 0x0FC6, 0},
    {0x102D, 0x1030, 0},
    {0x1032, 0x1037, 0},
    {0x1039, 0x103A, 0},
    {0x103D, 0x103E, 0},
    {0x1058, 0x1059, 0},
    {0x105E, 0x1060, 0},
    {0x1071, 0x1074, 0},
    {0x1082, 0x1082, 0},
    {0x1085, 0x1086, 0},
    {0x108D, 0x108D, 0},
    {0x109D, 0x109D, 0},
    {0x10FC, 0x10FC, 0},
    {0x135D, 0x135F, 0},
    {0x1712, 0x1714, 0},
    {0x1732, 0x1733, 0},
    {0x1752, 0x1753, 0},
    {0x1772, 0x1773, 0},
    {0x17B4, 0x17B5, 0},
    {0x17B7, 0x17BD, 0},
    {0x17C6, 0x17C6, 0},
    {0x17C9, 0x17D3, 0},
    {0x17D7, 0x17D7, 0},
    {0x17DD, 0x17DD, 0},
    {0x180B, 0x180D, 0},
    {0x180E, 0x180E, 0},
    {0x180F, 0x180F, 0},
    {0x1843, 0x1843, 0},
    {0x1885, 0x1886, 0},
    {0x18A9, 0x18A9, 0},
    {0x1920, 0x1922, 0},
    {0x1927, 0x1928, 0},
    {0x1932, 0x1932, 0},
    {0x1939, 0x193B, 0},
    {0x1A17, 0x1A18, 0},
    {0x1A1B, 0x1A1B, 0},
    {0x1A56, 0x1A56, 0},
    {0x1A58, 0x1A5E, 0},
    {0x1A60, 0x1A60, 0},
    {0x1A62, 0x1A62, 0},
    {0x1A65, 0x1A6C, 0},
    {0x1A73, 0x1A7C, 0},
    {0x1A7F, 0x1A7F, 0},
    {0x1AA7, 0x1AA7, 0},
    {0x1AB0, 0x1ABD, 0},
    {0x1ABE, 0x1ABE, 0},
    {0x1ABF, 0x1ACE, 0},
    {0x1B00, 0x1B03, 0},
    {0x1B34, 0x1B34, 0},
    {0x1B36, 0x1B3A, 0},
    {0x1B3C, 0x1B3C, 0},
    {0x1B42, 0x1B42, 0},
    {0x1B6B, 0x1B73, 0},
    {0x1B80, 0x1B81, 0},
    {0x1BA2, 0x1BA5, 0},
    {0x1BA8, 0x1BA9, 0},
    {0x1BAB, 0x1BAD, 0},
    {0x1BE6, 0x1BE6, 0},
    {0x1BE8, 0x1BE9, 0},
    {0x1BED, 0x1BED, 0},
    {0x1BEF, 0x1BF1, 0},
    {0x1C2C, 0x1C33, 0},
    {0x1C36, 0x1C37, 0},
    {0x1C78, 0x1C7D, 0},
    {0x1CD0, 0x1CD2, 0},
    {0x1CD4, 0x1CE0, 0},
    {0x1CE2, 0x1CE8, 0},
    {0x1CED, 0x1CED, 0},
    {0x1CF4, 0x1CF4, 0},
    {0x1CF8, 0x1CF9, 0},
    {0x1D2C, 0x1D6A, 0},
    {0x1D78, 0x1D78, 0},
    {0x1D9B, 0x1DBF, 0},
    {0x1DC0, 0x1DFF, 0},
    {0x1FBD, 0x1FBD, 0},
    {0x1FBF, 0x1FC1, 0},
    {0x1FCD, 0x1FCF, 0},
    {0x1FDD, 0x1FDF, 0},
    {0x1FED, 0x1FEF, 0},
    {0x1FFD, 0x1FFE, 0},
    {0x200B, 0x200F, 0},
    {0x2018, 0x2018, 0},
    {0x2019, 0x2019, 0},
    {0x2024, 0x2024, 0},
    {0x2027, 0x2027, 0},
    {0x202A, 0x202E, 0},
    {0x2060, 0x2064, 0},
    {0x2066, 0x206F, 0},
    {0x2071, 0x2071, 0},
    {0x207F, 0x207F, 0},
    {0x2090, 0x209C, 0},
    {0x20D0, 0x20DC, 0},
    {0x20DD, 0x20E0, 0},
    {0x20E1, 0x20E1, 0},
    {0x20E2, 0x20E4, 0},
    {0x20E5, 0x20F0, 0},
    {0x2C7C, 0x2C7D, 0},
    {0x2CEF, 0x2CF1, 0},
    {0x2D6F, 0x2D6F, 0},
    {0x2D7F, 0x2D7F, 0},
    {0x2DE0, 0x2DFF, 0},
    {0x2E2F, 0x2E2F, 0},
    {0x3005, 0x3005, 0},
    {0x302A, 0x302D, 0},
    {0x3031, 0x3035, 0},
    {0x303B, 0x303B, 0},
    {0x3099, 0x309A, 0},
    {0x309B, 0x309C, 0},
    {0x309D, 0x309E, 0},
    {0x30FC, 0x30FE, 0},
    {0xA015, 0xA015, 0},
    {0xA4F8, 0xA4FD, 0},
    {0xA60C, 0xA60C, 0},
    {0xA66F, 0xA66F, 0},
    {0xA670, 0xA672, 0},
    {0xA674, 0xA67D, 0},
    {0xA67F, 0xA67F, 0},
    {0xA69C, 0xA69D, 0},
    {0xA69E, 0xA69F, 0},
    {0xA6F0, 0xA6F1, 0},
    {0xA700, 0xA716, 0},
    {0xA717, 0xA71F, 0},
    {0xA720, 0xA721, 0},
    {0xA770, 0xA770, 0},
    {0xA788, 0xA788, 0},
    {0xA789, 0xA78A, 0},
    {0xA7F2, 0xA7F4, 0},
    {0xA7F8, 0xA7F9, 0},
    {0xA802, 0xA802, 0},
    {0xA806, 0xA806, 0},
    {0xA80B, 0xA80B, 0},
    {0xA825, 0xA826, 0},
    {0xA82C, 0xA82C, 0},
    {0xA8C4, 0xA8C5, 0},
    {0xA8E0, 0xA8F1, 0},
    {0xA8FF, 0xA8FF, 0},
    {0xA926, 0xA92D, 0},
    {0xA947, 0xA951, 0},
    {0xA980, 0xA982, 0},
    {0xA9B3, 0xA9B3, 0},
    {0xA9B6, 0xA9B9, 0},
    {0xA9BC, 0xA9BD, 0},
    {0xA9CF, 0xA9CF, 0},
    {0xA9E5, 0xA9E5, 0},
    {0xA9E6, 0xA9E6, 0},
    {0xAA29, 0xAA2E, 0},
    {0xAA31, 0xAA32, 0},
    {0xAA35, 0xAA36, 0},
    {0xAA43, 0xAA43, 0},
    {0xAA4C, 0xAA4C, 0},
    {0xAA70, 0xAA70, 0},
    {0xAA7C, 0xAA7C, 0},
    {0xAAB0, 0xAAB0, 0},
    {0xAAB2, 0xAAB4, 0},
    {0xAAB7, 0xAAB8, 0},
    {0xAABE, 0xAABF, 0},
    {0xAAC1, 0xAAC1, 0},
    {0xAADD, 0xAADD, 0},
    {0xAAEC, 0xAAED, 0},
    {0xAAF3, 0xAAF4, 0},
    {0xAAF6, 0xAAF6, 0},
    {0xAB5B, 0xAB5B, 0},
    {0xAB5C, 0xAB5F, 0},
    {0xAB69, 0xAB69, 0},
    {0xAB6A, 0xAB6B, 0},
    {0xABE5, 0xABE5, 0},
    {0xABE8, 0xABE8, 0},
    {0xABED, 0xABED, 0},
    {0xFB1E, 0xFB1E, 0},
    {0xFBB2, 0xFBC2, 0},
    {0xFE00, 0xFE0F, 0},
    {0xFE13, 0xFE13, 0},
    {0xFE20, 0xFE2F, 0},
    {0xFE52, 0xFE52, 0},
    {0xFE55, 0xFE55, 0},
    {0xFEFF, 0xFEFF, 0},
    {0xFF07, 0xFF07, 0},
    {0xFF0E, 0xFF0E, 0},
    {0xFF1A, 0xFF1A, 0},
    {0xFF3E, 0xFF3E, 0},
    {0xFF40, 0xFF40, 0},
    {0xFF70, 0xFF70, 0},
    {0xFF9E, 0xFF9F, 0},
    {0xFFE3, 0xFFE3, 0},
    {0xFFF9, 0xFFFB, 0},
    {0x101FD, 0x101FD, 0},
    {0x102E0, 0x102E0, 0},
    {0x10376, 0x1037A, 0},
    {0x10780, 0x10785, 0},
    {0x10787, 0x107B0, 0},
    {0x107B2, 0x107BA, 0},
    {0x10A01, 0x10A03, 0},
    {0x10A05, 0x10A06, 0},
    {0x10A0C, 0x10A0F, 0},
    {0x10A38, 0x10A3A, 0},
    {0x10A3F, 0x10A3F, 0},
    {0x10AE5, 0x10AE6, 0},
    {0x10D24, 0x10D27, 0},
    {0x10D4E, 0x10D4E, 0},
    {0x10D69, 0x10D6D, 0},
    {0x10D6F, 0x10D6F, 0},
    {0x10EAB, 0x10EAC, 0},
    {0x10EFC, 0x10EFF, 0},
    {0x10F46, 0x10F50, 0},
    {0x10F82, 0x10F85, 0},
    {0x11001, 0x11001, 0},
    {0x11038, 0x11046, 0},
    {0x11070, 0x11070, 0},
    {0x11073, 0x11074, 0},
    {0x1107F, 0x11081, 0},
    {0x110B3, 0x110B6, 0},
    {0x110B9, 0x110BA, 0},
    {0x110BD, 0x110BD, 0},
    {0x110C2, 0x110C2, 0},
    {0x110CD, 0x110CD, 0},
    {0x11100, 0x11102, 0},
    {0x11127, 0x1112B, 0},
    {0x1112D, 0x11134, 0},
    {0x11173, 0x11173, 0},
    {0x11180, 0x11181, 0},
    {0x111B6, 0x111BE, 0},
    {0x111C9, 0x111CC, 0},
    {0x111CF, 0x111CF, 0},
    {0x1122F, 0x11231, 0},
    {0x11234, 0x11234, 0},
    {0x11236, 0x11237, 0},
    {0x1123E, 0x1123E, 0},
    {0x11241, 0x11241, 0},
    {0x112DF, 0x112DF, 0},
    {0x112E3, 0x112EA, 0},
    {0x11300, 0x11301, 0},
    {0x1133B, 0x1133C, 0},
    {0x11340, 0x11340, 0},
    {0x11366, 0x1136C, 0},
    {0x11370, 0x11374, 0},
    {0x113BB, 0x113C0, 0},
    {0x113CE, 0x113CE, 0},
    {0x113D0, 0x113D0, 0},
    {0x113D2, 0x113D2, 0},
    {0x113E1, 0x113E2, 0},
    {0x11438, 0x1143F, 0},
    {0x11442, 0x11444, 0},
    {0x11446, 0x11446, 0},
    {0x1145E, 0x1145E, 0},
    {0x114B3, 0x114B8, 0},
    {0x114BA, 0x114BA, 0},
    {0x114BF, 0x114C0, 0},
    {0x114C2, 0x114C3, 0},
    {0x115B2, 0x115B5, 0},
    {0x115BC, 0x115BD, 0},
    {0x115BF, 0x115C0, 0},
    {0x115DC, 0x115DD, 0},
    {0x11633, 0x1163A, 0},
    {0x1163D, 0x1163D, 0},
    {0x1163F, 0x11640, 0},
    {0x116AB, 0x116AB, 0},
    {0x116AD, 0x116AD, 0},
    {0x116B0, 0x116B5, 0},
    {0x116B7, 0x116B7, 0},
    {0x1171D, 0x1171D, 0},
    {0x1171F, 0x1171F, 0},
    {0x11722, 0x11725, 0},
    {0x11727, 0x1172B, 0},
    {0x1182F, 0x11837, 0},
    {0x11839, 0x1183A, 0},
    {0x1193B, 0x1193C, 0},
    {0x1193E, 0x1193E, 0},
    {0x11943, 0x11943, 0},
    {0x119D4, 0x119D7, 0},
    {0x119DA, 0x119DB, 0},
    {0x119E0, 0x119E0, 0},
    {0x11A01, 0x11A0A, 0},
    {0x11A33, 0x11A38, 0},
    {0x11A3B, 0x11A3E, 0},
    {0x11A47, 0x11A47, 0},
    {0x11A51, 0x11A56, 0},
    {0x11A59, 0x11A5B, 0},
    {0x11A8A, 0x11A96, 0},
    {0x11A98, 0x11A99, 0},
    {0x11C30, 0x11C36, 0},
    {0x11C38, 0x11C3D, 0},
    {0x11C3F, 0x11C3F, 0},
    {0x11C92, 0x11CA7, 0},
    {0x11CAA, 0x11CB0, 0},
    {0x11CB2, 0x11CB3, 0},
    {0x11CB5, 0x11CB6, 0},
    {0x11D31, 0x11D36, 0},
    {0x11D3A, 0x11D3A, 0},
    {0x11D3C, 0x11D3D, 0},
    {0x11D3F, 0x11D45, 0},
    {0x11D47, 0x11D47, 0},
    {0x11D90, 0x11D91, 0},
    {0x11D95, 0x11D95, 0},
    {0x11D97, 0x11D97, 0},
    {0x11EF3, 0x11EF4, 0},
    {0x11F00, 0x11F01, 0},
    {0x11F36, 0x11F3A, 0},
    {0x11F40, 0x11F40, 0},
    {0x11F42, 0x11F42, 0},
    {0x11F5A, 0x11F5A, 0},
    {0x13430, 0x1343F, 0},
    {0x13440, 0x13440, 0},
    {0x13447, 0x13455, 0},
    {0x1611E, 0x16129, 0},
    {0x1612D, 0x1612F, 0},
    {0x16AF0, 0x16AF4, 0},
    {0x16B30, 0x16B36, 0},
    {0x16B40, 0x16B43, 0},
    {0x16D40, 0x16D42, 0},
    {0x16D6B, 0x16D6C, 0},
    {0x16F4F, 0x16F4F, 0},
    {0x16F8F, 0x16F92, 0},
    {0x16F93, 0x16F9F, 0},
    {0x16FE0, 0x16FE1, 0},
    {0x16FE3, 0x16FE3, 0},
    {0x16FE4, 0x16FE4, 0},
    {0x1AFF0, 0x1AFF3, 0},
    {0x1AFF5, 0x1AFFB, 0},
    {0x1AFFD, 0x1AFFE, 0},
    {0x1BC9D, 0x1BC9E, 0},
    {0x1BCA0, 0x1BCA3, 0},
    {0x1CF00, 0x1CF2D, 0},
    {0x1CF30, 0x1CF46, 0},
    {0x1D167, 0x1D169, 0},
    {0x1D173, 0x1D17A, 0},
    {0x1D17B, 0x1D182, 0},
    {0x1D185, 0x1D18B, 0},
    {0x1D1AA, 0x1D1AD, 0},
    {0x1D242, 0x1D244, 0},
    {0x1DA00, 0x1DA36, 0},
    {0x1DA3B, 0x1DA6C, 0},
    {0x1DA75, 0x1DA75, 0},
    {0x1DA84, 0x1DA84, 0},
    {0x1DA9B, 0x1DA9F, 0},
    {0x1DAA1, 0x1DAAF, 0},
    {0x1E000, 0x1E006, 0},
    {0x1E008, 0x1E018, 0},
    {0x1E01B, 0x1E021, 0},
    {0x1E023, 0x1E024, 0},
    {0x1E026, 0x1E02A, 0},
    {0x1E030, 0x1E06D, 0},
    {0x1E08F, 0x1E08F, 0},
    {0x1E130, 0x1E136, 0},
    {0x1E137, 0x1E13D, 0},
    {0x1E2AE, 0x1E2AE, 0},
    {0x1E2EC, 0x1E2EF, 0},
    {0x1E4EB, 0x1E4EB, 0},
    {0x1E4EC, 0x1E4EF, 0},
    {0x1E5EE, 0x1E5EF, 0},
    {0x1E8D0, 0x1E8D6, 0},
    {0x1E944, 0x1E94A, 0},
    {0x1E94B, 0x1E94B, 0},
    {0x1F3FB, 0x1F3FF, 0},
    {0xE0001, 0xE0001, 0},
    {0xE0020, 0xE007F, 0},
    {0xE0100, 0xE01EF, 0},
};

static bool blorp_codepoint_in_ranges(int32_t cp, const blorp_unicode_case_range* ranges, size_t count) {
    size_t lo = 0;
    size_t hi = count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].start) {
            hi = mid;
        } else if (cp > ranges[mid].end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

static bool blorp_unicode_case_lookup(int32_t cp, const blorp_unicode_case_range* ranges, size_t range_count, const blorp_unicode_case_special* specials, size_t special_count, int32_t out[3], uint8_t* out_len) {
    size_t lo = 0;
    size_t hi = special_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (cp < specials[mid].codepoint) {
            hi = mid;
        } else if (cp > specials[mid].codepoint) {
            lo = mid + 1;
        } else {
            *out_len = specials[mid].length;
            out[0] = specials[mid].mapping[0];
            out[1] = specials[mid].mapping[1];
            out[2] = specials[mid].mapping[2];
            return true;
        }
    }

    lo = 0;
    hi = range_count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid].start) {
            hi = mid;
        } else if (cp > ranges[mid].end) {
            lo = mid + 1;
        } else {
            *out_len = 1;
            out[0] = cp + ranges[mid].delta;
            out[1] = 0;
            out[2] = 0;
            return true;
        }
    }

    *out_len = 1;
    out[0] = cp;
    out[1] = 0;
    out[2] = 0;
    return false;
}

static bool blorp_utf8_decode_span(const blorp_String* s, long pos, blorp_utf8_span* span) {
    unsigned char b0 = (unsigned char)s->data[pos];
    span->start = pos;
    span->length = 1;
    span->codepoint = b0;
    span->valid = false;

    if (b0 < 0x80) {
        span->valid = true;
        return true;
    }

    int needed = 0;
    int32_t cp = 0;
    if ((b0 & 0xE0) == 0xC0) {
        needed = 2;
        cp = b0 & 0x1F;
    } else if ((b0 & 0xF0) == 0xE0) {
        needed = 3;
        cp = b0 & 0x0F;
    } else if ((b0 & 0xF8) == 0xF0) {
        needed = 4;
        cp = b0 & 0x07;
    } else {
        return false;
    }

    if (pos + needed > s->len) return false;
    for (int i = 1; i < needed; i++) {
        unsigned char bx = (unsigned char)s->data[pos + i];
        if ((bx & 0xC0) != 0x80) return false;
        cp = (cp << 6) | (bx & 0x3F);
    }

    if ((needed == 2 && cp < 0x80) ||
        (needed == 3 && cp < 0x800) ||
        (needed == 4 && cp < 0x10000) ||
        (cp >= 0xD800 && cp <= 0xDFFF) ||
        cp > 0x10FFFF) {
        return false;
    }

    span->length = needed;
    span->codepoint = cp;
    span->valid = true;
    return true;
}

static bool blorp_is_cased_codepoint(int32_t cp) {
    return blorp_codepoint_in_ranges(cp, blorp_cased_ranges, sizeof(blorp_cased_ranges) / sizeof(blorp_cased_ranges[0]));
}

static bool blorp_is_case_ignorable_codepoint(int32_t cp) {
    return blorp_codepoint_in_ranges(cp, blorp_case_ignorable_ranges, sizeof(blorp_case_ignorable_ranges) / sizeof(blorp_case_ignorable_ranges[0]));
}

static bool blorp_is_final_sigma_context(const blorp_utf8_span* spans, long count, long index) {
    bool has_cased_before = false;
    for (long i = index - 1; i >= 0; i--) {
        if (!spans[i].valid) break;
        int32_t cp = spans[i].codepoint;
        if (blorp_is_case_ignorable_codepoint(cp)) continue;
        has_cased_before = blorp_is_cased_codepoint(cp);
        break;
    }
    if (!has_cased_before) return false;

    for (long i = index + 1; i < count; i++) {
        if (!spans[i].valid) break;
        int32_t cp = spans[i].codepoint;
        if (blorp_is_case_ignorable_codepoint(cp)) continue;
        return !blorp_is_cased_codepoint(cp);
    }
    return true;
}

static bool blorp_string_is_ascii(const blorp_String* s) {
    for (long i = 0; i < s->len; i++) {
        if (((unsigned char)s->data[i]) >= 0x80) return false;
    }
    return true;
}

static blorp_String* blorp_ascii_case_map(const blorp_String* s, bool upper) {
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + (size_t)s->len + 1);
    result->len = s->len;
    result->capacity = s->len;
    for (long i = 0; i < s->len; i++) {
        unsigned char b = (unsigned char)s->data[i];
        if (upper) {
            result->data[i] = (char)((b >= 'a' && b <= 'z') ? b - 32 : b);
        } else {
            result->data[i] = (char)((b >= 'A' && b <= 'Z') ? b + 32 : b);
        }
    }
    result->data[s->len] = '\0';
    return result;
}

static void blorp_case_mapping_for_span(const blorp_utf8_span* spans, long count, long index, bool upper, int32_t out[3], uint8_t* out_len) {
    int32_t cp = spans[index].codepoint;
    if (!upper && cp == 0x03A3 && blorp_is_final_sigma_context(spans, count, index)) {
        *out_len = 1;
        out[0] = 0x03C2;
        out[1] = 0;
        out[2] = 0;
        return;
    }

    if (upper) {
        blorp_unicode_case_lookup(cp, blorp_upper_ranges, sizeof(blorp_upper_ranges) / sizeof(blorp_upper_ranges[0]), blorp_upper_specials, sizeof(blorp_upper_specials) / sizeof(blorp_upper_specials[0]), out, out_len);
    } else {
        blorp_unicode_case_lookup(cp, blorp_lower_ranges, sizeof(blorp_lower_ranges) / sizeof(blorp_lower_ranges[0]), blorp_lower_specials, sizeof(blorp_lower_specials) / sizeof(blorp_lower_specials[0]), out, out_len);
    }
}

static blorp_String* blorp_unicode_case_map(const blorp_String* s, bool upper) {
    if (!s || s->len == 0) return blorp_string_literal("");
    if (blorp_string_is_ascii(s)) return blorp_ascii_case_map(s, upper);

    blorp_utf8_span* spans = (blorp_utf8_span*)blorp_malloc_checked(sizeof(blorp_utf8_span) * (size_t)s->len);
    long count = 0;
    for (long pos = 0; pos < s->len; ) {
        blorp_utf8_span span;
        blorp_utf8_decode_span(s, pos, &span);
        spans[count++] = span;
        pos += span.length;
    }

    size_t out_len = 0;
    for (long i = 0; i < count; i++) {
        if (!spans[i].valid) {
            out_len = blorp_checked_add(out_len, (size_t)spans[i].length);
            continue;
        }
        int32_t mapped[3];
        uint8_t mapped_len;
        blorp_case_mapping_for_span(spans, count, i, upper, mapped, &mapped_len);
        for (uint8_t j = 0; j < mapped_len; j++) {
            unsigned char tmp[4];
            out_len = blorp_checked_add(out_len, (size_t)blorp_utf8_encode(mapped[j], tmp));
        }
    }

    if (out_len > LONG_MAX) {
        fprintf(stderr, "blorp: string length overflow during Unicode case conversion\n");
        exit(1);
    }

    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + out_len + 1);
    result->len = (long)out_len;
    result->capacity = (long)out_len;
    size_t write = 0;
    for (long i = 0; i < count; i++) {
        if (!spans[i].valid) {
            memcpy(result->data + write, s->data + spans[i].start, (size_t)spans[i].length);
            write += (size_t)spans[i].length;
            continue;
        }
        int32_t mapped[3];
        uint8_t mapped_len;
        blorp_case_mapping_for_span(spans, count, i, upper, mapped, &mapped_len);
        for (uint8_t j = 0; j < mapped_len; j++) {
            unsigned char encoded[4];
            int len = blorp_utf8_encode(mapped[j], encoded);
            memcpy(result->data + write, encoded, (size_t)len);
            write += (size_t)len;
        }
    }
    result->data[out_len] = '\0';
    free(spans);
    return result;
}

blorp_String* blorp_upper(const blorp_String* s) {
    return blorp_unicode_case_map(s, true);
}

blorp_String* blorp_lower(const blorp_String* s) {
    return blorp_unicode_case_map(s, false);
}


blorp_String* blorp_from_char(int32_t c) {
    unsigned char buf[4];
    int len = blorp_utf8_encode(c, buf);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_from_chars(blorp_List* chars) {
    if (!chars || chars->len == 0) {
        blorp_String* empty = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 1);
        empty->len = 0;
        empty->capacity = 0;
        empty->data[0] = '\0';
        return empty;
    }
    // Two-pass: compute total UTF-8 byte length, then encode
    long total_len = 0;
    for (long i = 0; i < chars->len; i++) {
        int32_t c = (int32_t)(intptr_t)blorp_list_get(chars, i);
        unsigned char tmp[4];
        total_len += blorp_utf8_encode(c, tmp);
    }
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + total_len + 1);
    str->len = total_len;
    str->capacity = total_len;
    long pos = 0;
    for (long i = 0; i < chars->len; i++) {
        int32_t c = (int32_t)(intptr_t)blorp_list_get(chars, i);
        unsigned char tmp[4];
        int n = blorp_utf8_encode(c, tmp);
        memcpy(str->data + pos, tmp, n);
        pos += n;
    }
    str->data[total_len] = '\0';
    return str;
}

// StringBuilder-like operations (COW-aware string building)
blorp_String* blorp_string_with_capacity(long cap) {
    if (cap < 16) cap = 16;
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + cap + 1);
    str->len = 0;
    str->capacity = cap;
    str->data[0] = '\0';
    return str;
}

blorp_String* blorp_string_append(blorp_String* s, const blorp_String* other) {
    if (!other || other->len == 0) return s ? s : __blorp_empty_str;
    if (!s) s = blorp_string_with_capacity(other->len);

    // COW: if refcount > 1, make a copy
    if (!blorp_is_unique(s)) {
        long need_cap = s->len + other->len;
        if (need_cap < s->capacity) need_cap = s->capacity;
        blorp_String* copy = (blorp_String*)blorp_alloc(sizeof(blorp_String) + need_cap + 1);
        copy->len = s->len;
        copy->capacity = need_cap;
        memcpy(copy->data, s->data, s->len + 1);
        blorp_release((void*)s);
        s = copy;
    }

    // Grow if needed
    long needed = s->len + other->len;
    if (needed > s->capacity) {
        long new_cap = needed * 2;
        blorp_String* new_str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + new_cap + 1);
        new_str->len = s->len;
        new_str->capacity = new_cap;
        memcpy(new_str->data, s->data, s->len);
        blorp_release((void*)s);
        s = new_str;
    }

    memcpy(s->data + s->len, other->data, other->len);
    s->len += other->len;
    s->data[s->len] = '\0';
    return s;
}

// IR intrinsic: allocate an empty mutable string with given byte capacity.
// len is set to 0; data is zeroed. Caller fills bytes via string_set_byte.
blorp_String* blorp_string_alloc(long capacity) {
    if (capacity < 1) capacity = 1;
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + capacity + 1);
    str->len = 0;
    str->capacity = capacity;
    str->data[0] = '\0';
    return str;
}

long blorp_string_find_byte_from(const blorp_String* s, long byte, long start) {
    if (!s || start < 0 || start >= s->len) return -1;
    const char* found = (const char*)memchr(
        s->data + start,
        (unsigned char)byte,
        (size_t)(s->len - start)
    );
    return found ? (long)(found - s->data) : -1;
}

// IR intrinsic: COW check — if shared (or immortal), return a mutable copy.
// If already unique, return as-is.
blorp_String* blorp_string_cow(blorp_String* s) {
    if (!s) return blorp_string_alloc(1);
    if (blorp_is_unique(s)) return s;
    blorp_String* copy = (blorp_String*)blorp_alloc(sizeof(blorp_String) + s->capacity + 1);
    copy->len = s->len;
    copy->capacity = s->capacity;
    memcpy(copy->data, s->data, s->len);
    copy->data[s->len] = '\0';
    blorp_release(s);
    return copy;
}

// IR intrinsic: COW + ensure byte capacity >= min_cap.
// Returns a unique string with at least min_cap bytes of capacity.
blorp_String* blorp_string_ensure_capacity(blorp_String* s, long min_cap) {
    if (!s) return blorp_string_alloc(min_cap);
    if (blorp_is_unique(s) && s->capacity >= min_cap) return s;
    long new_cap = s->capacity;
    if (new_cap < 1) new_cap = 1;
    while (new_cap < min_cap) new_cap *= 2;
    blorp_String* copy = (blorp_String*)blorp_alloc(sizeof(blorp_String) + new_cap + 1);
    copy->len = s->len;
    copy->capacity = new_cap;
    memcpy(copy->data, s->data, s->len);
    copy->data[s->len] = '\0';
    blorp_release(s);
    return copy;
}

// FFI copy: create independent deep copy of a string (refcount = 1)
blorp_String* blorp_string_copy_ffi(blorp_String* src) {
    if (!src) return blorp_string_create("");
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + src->len + 1);
    str->len = src->len;
    str->capacity = src->len;
    memcpy(str->data, src->data, src->len);
    str->data[src->len] = '\0';
    return str;
}

// ============================================================================
// Print and Conversion
// ============================================================================

void blorp_print(blorp_String* s) {
    if (s && s->len > 0) {
        fwrite(s->data, 1, s->len, stdout);
    }
    putchar('\n');
}

void blorp_puts(blorp_String* s) {
    if (s && s->len > 0) {
        fwrite(s->data, 1, s->len, stdout);
    }
}

void blorp_err_print(blorp_String* s) {
    if (s && s->len > 0) {
        fwrite(s->data, 1, s->len, stderr);
    }
    fputc('\n', stderr);
}

blorp_String* blorp_read_all(void) {
    size_t cap = 4096;
    size_t len = 0;
    char* buf = (char*)malloc(cap);
    if (!buf) {
        blorp_String* empty = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 1);
        empty->len = 0;
        empty->capacity = 0;
        empty->data[0] = '\0';
        return empty;
    }
    size_t n;
    while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
        len += n;
        if (len == cap) {
            if (cap > SIZE_MAX / 2) break;
            cap *= 2;
            char* newbuf = (char*)realloc(buf, cap);
            if (!newbuf) break;
            buf = newbuf;
        }
    }
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    if (len > 0) memcpy(result->data, buf, len);
    result->data[len] = '\0';
    free(buf);
    return result;
}

static blorp_String* blorp_read_line_nullable(void) {
    char* line = NULL;
    size_t cap = 0;
    ssize_t len = getline(&line, &cap, stdin);

    if (len == -1) {
        if (feof(stdin) && isatty(STDIN_FILENO)) {
            clearerr(stdin);
        }
        free(line);
        return NULL;
    }

    // Strip trailing newline
    if (len > 0 && line[len-1] == '\n') {
        len--;
    }

    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    if (len > 0) memcpy(result->data, line, len);
    result->data[len] = '\0';

    free(line);
    return result;
}

blorp_String* blorp_read_line(void) {
    return blorp_read_line_nullable();
}

blorp_String* blorp_read_line_opt(void) {
    return blorp_read_line();
}

blorp_String* blorp_read_line_or_empty(void) {
    blorp_String* line = blorp_read_line_nullable();
    if (line) return line;
    blorp_String* empty = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 1);
    empty->len = 0;
    empty->capacity = 0;
    empty->data[0] = '\0';
    return empty;
}

blorp_String* blorp_input(blorp_String* prompt) {
    if (prompt && prompt->len > 0) {
        fwrite(prompt->data, 1, prompt->len, stdout);
        fflush(stdout);
    }
    return blorp_read_line_nullable();
}

blorp_String* blorp_input_opt(blorp_String* prompt) {
    return blorp_input(prompt);
}

blorp_String* blorp_input_or_empty(blorp_String* prompt) {
    if (prompt && prompt->len > 0) {
        fwrite(prompt->data, 1, prompt->len, stdout);
        fflush(stdout);
    }
    return blorp_read_line_or_empty();
}

// (removed blorp_exit — now IR intrinsic)

blorp_String* blorp_to_string(long i) {
    char buf[32];
    int len = snprintf(buf, sizeof(buf), "%ld", i);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

// Int128/UInt128 to_string: digit-by-digit decomposition (no printf format for __int128)
blorp_String* blorp_int128_to_string(__int128 v) {
    char buf[42]; // enough for -170141183460469231731687303715884105728
    if (v == 0) {
        blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 2);
        str->len = 1; str->capacity = 1;
        str->data[0] = '0'; str->data[1] = '\0';
        return str;
    }
    int neg = 0;
    unsigned __int128 uv;
    if (v < 0) { neg = 1; uv = -(unsigned __int128)v; }
    else { uv = (unsigned __int128)v; }
    int pos = 41;
    buf[pos] = '\0';
    while (uv > 0) { pos--; buf[pos] = '0' + (int)(uv % 10); uv /= 10; }
    if (neg) { pos--; buf[pos] = '-'; }
    int len = 41 - pos;
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len; str->capacity = len;
    memcpy(str->data, buf + pos, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_uint128_to_string(unsigned __int128 v) {
    char buf[42]; // enough for 340282366920938463463374607431768211455
    if (v == 0) {
        blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 2);
        str->len = 1; str->capacity = 1;
        str->data[0] = '0'; str->data[1] = '\0';
        return str;
    }
    int pos = 41;
    buf[pos] = '\0';
    while (v > 0) { pos--; buf[pos] = '0' + (int)(v % 10); v /= 10; }
    int len = 41 - pos;
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len; str->capacity = len;
    memcpy(str->data, buf + pos, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_float_to_string(double f) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%g", f);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_format_float(double f, long decimals) {
    char buf[350]; /* DBL_MAX with 20 decimals needs ~332 chars */
    if (decimals < 0) decimals = 0;
    if (decimals > 20) decimals = 20;
    int len = snprintf(buf, sizeof(buf), "%.*f", (int)decimals, f);
    if (len < 0) len = 0;
    if (len >= (int)sizeof(buf)) len = (int)sizeof(buf) - 1;
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

blorp_String* blorp_float32_to_string(float f) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%g", (double)f);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

#ifdef __FLT16_MAX__
blorp_String* blorp_float16_to_string(_Float16 f) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "%g", (double)f);
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}
#endif // __FLT16_MAX__

// Immortal singleton strings (avoid per-call allocation)
static blorp_String* __blorp_true_str = NULL;
static blorp_String* __blorp_false_str = NULL;

__attribute__((constructor))
static void __blorp_init_singleton_strings(void) {
    __blorp_empty_str = blorp_string_literal("");
    __blorp_true_str = blorp_string_literal("True");
    __blorp_false_str = blorp_string_literal("False");
}

blorp_String* blorp_bool_to_string(bool b) {
    return b ? __blorp_true_str : __blorp_false_str;
}

// Long-taking wrapper for packed enum tensor to_string callback
blorp_String* blorp_bool_to_string_long(long b) {
    return b ? __blorp_true_str : __blorp_false_str;
}

long blorp_to_int(blorp_String* s) {
    if (!s || s->len == 0) return 0;
    return strtol(s->data, NULL, 10);
}

double blorp_to_float(blorp_String* s) {
    if (!s || s->len == 0) return 0.0;
    return strtod(s->data, NULL);
}

// Sized integer conversions — truncating casts from long
int8_t blorp_to_int8(long x) { return (int8_t)x; }
int16_t blorp_to_int16(long x) { return (int16_t)x; }
int32_t blorp_to_int32(long x) { return (int32_t)x; }
__int128 blorp_to_int128(long x) { return (__int128)x; }
uint8_t blorp_to_uint8(long x) { return (uint8_t)x; }
uint16_t blorp_to_uint16(long x) { return (uint16_t)x; }
uint32_t blorp_to_uint32(long x) { return (uint32_t)x; }
uint64_t blorp_to_uint64(long x) { return (uint64_t)x; }
unsigned __int128 blorp_to_uint128(long x) { return (unsigned __int128)x; }

// ============================================================================
// List Operations
// ============================================================================

static int blorp_list_valid_inline_size(int16_t elem_size) {
    return elem_size > 0;
}

static size_t blorp_list_stride(const blorp_List* list) {
    return (list && list->storage_mode == BLORP_LIST_STORAGE_INLINE)
        ? (size_t)list->elem_size
        : sizeof(void*);
}

static blorp_List* blorp_list_new_layout(long initial_capacity, uint8_t storage_mode, int16_t elem_size) {
    if (initial_capacity < 1) initial_capacity = 1;
    if (storage_mode != BLORP_LIST_STORAGE_INLINE || !blorp_list_valid_inline_size(elem_size)) {
        storage_mode = BLORP_LIST_STORAGE_POINTER;
        elem_size = (int16_t)sizeof(void*);
    }
    size_t stride = storage_mode == BLORP_LIST_STORAGE_INLINE ? (size_t)elem_size : sizeof(void*);
    blorp_List* list = (blorp_List*)blorp_alloc(blorp_checked_add(sizeof(blorp_List), blorp_checked_mul(initial_capacity, stride)));
    BLORP_TAG(list, "List");
    list->len = 0;
    list->capacity = initial_capacity;
    list->elem_release = NULL;
    list->elem_size = elem_size;
    list->storage_mode = storage_mode;
    BLORP_SET_DESTRUCTOR(list, blorp_list_destroy);
    return list;
}

blorp_List* blorp_list_new(long initial_capacity) {
    return blorp_list_new_layout(initial_capacity, BLORP_LIST_STORAGE_POINTER, (int16_t)sizeof(void*));
}

blorp_List* blorp_list_new_inline(long initial_capacity, int16_t elem_size) {
    return blorp_list_new_layout(initial_capacity, BLORP_LIST_STORAGE_INLINE, elem_size);
}

static blorp_List* blorp_list_new_result_layout(long initial_capacity, int result_elem_is_rc, uint8_t storage_mode, int16_t elem_size) {
    blorp_List* list = blorp_list_new_layout(initial_capacity, storage_mode, elem_size);
    if (result_elem_is_rc && list->storage_mode == BLORP_LIST_STORAGE_POINTER) {
        blorp_list_init_elem_release(list, blorp_elem_release_fn);
    }
    return list;
}

// (removed blorp_list_len — now IR intrinsic)

static void blorp_list_store_raw(blorp_List* list, long index, void* value) {
    if (!list || index < 0 || index >= list->capacity) return;
    if (list->storage_mode == BLORP_LIST_STORAGE_INLINE) {
        void* slot = (char*)list->data + index * list->elem_size;
        if (list->elem_size <= (int16_t)sizeof(uintptr_t)) {
            uintptr_t bits = (uintptr_t)value;
            memcpy(slot, &bits, list->elem_size);
        } else if (value) {
            memcpy(slot, value, list->elem_size);
        } else {
            memset(slot, 0, list->elem_size);
        }
    } else {
        list->data[index] = value;
    }
}

static void blorp_list_store_raw_copy(blorp_List* list, long index, const void* value) {
    if (!list || index < 0 || index >= list->capacity) return;
    if (list->storage_mode == BLORP_LIST_STORAGE_INLINE) {
        void* slot = (char*)list->data + index * list->elem_size;
        if (value) {
            memcpy(slot, value, list->elem_size);
        } else {
            memset(slot, 0, list->elem_size);
        }
    } else {
        list->data[index] = (void*)value;
    }
}

void blorp_list_set_raw(blorp_List* list, long index, void* value) {
    blorp_list_store_raw(list, index, value);
}

void blorp_list_set_raw_copy(blorp_List* list, long index, const void* value) {
    blorp_list_store_raw_copy(list, index, value);
}

static void blorp_list_store_callback_result(blorp_List* list, long index, void* value, uint8_t result_value_encoding) {
    if (result_value_encoding == BLORP_LIST_CALLBACK_BOXED_STRUCT && list && list->storage_mode == BLORP_LIST_STORAGE_INLINE) {
        if (value) {
            blorp_list_store_raw_copy(list, index, (char*)value + sizeof(blorp_Object));
            blorp_release(value);
        } else {
            blorp_list_store_raw_copy(list, index, NULL);
        }
        return;
    }
    blorp_list_store_raw(list, index, value);
}

static void blorp_list_push_callback_result(blorp_List* list, void* value, uint8_t result_value_encoding) {
    if (!list) {
        if (result_value_encoding == BLORP_LIST_CALLBACK_BOXED_STRUCT && value) blorp_release(value);
        return;
    }
    blorp_list_store_callback_result(list, list->len++, value, result_value_encoding);
}

__attribute__((always_inline))
static inline void* blorp_list_get_unchecked(blorp_List* list, long index) {
#ifndef NDEBUG
    assert(list && index >= 0 && index < list->len);
#endif
    if (list->storage_mode == BLORP_LIST_STORAGE_INLINE) {
        if (list->elem_size > (int16_t)sizeof(uintptr_t)) {
            return (void*)((char*)list->data + index * list->elem_size);
        }
        uintptr_t bits = 0;
        memcpy(&bits, (char*)list->data + index * list->elem_size, list->elem_size);
        return (void*)bits;
    }
    return list->data[index];
}

// Safe: returns NULL on bounds error (for-in loops already have bounds checks)
__attribute__((always_inline))
inline void* blorp_list_get(blorp_List* list, long index) {
    if (__builtin_expect(!list || index < 0 || index >= list->len, 0)) {
        return NULL;
    }
    return blorp_list_get_unchecked(list, index);
}

// Option-compatible struct for runtime functions
// Layout matches generated Option type (blorp_Object header for ARC compatibility)
typedef struct {
    blorp_Object header;
    int tag;
    unsigned long release_mask;
    union {
        struct { void* field0; } Some;
        char None;
    } data;
} blorp_Option;

#define BLORP_TAG_SOME 0
#define BLORP_TAG_NONE 1

// Stack-allocated Option for primitive types — no heap, no ARC, no destructor.
// Tag values match BLORP_TAG_SOME/NONE for consistency.
typedef struct { int tag; long value; } blorp_StackOption_Void;
typedef struct { int tag; long value; } blorp_StackOption_Int;
typedef struct { int tag; int8_t value; } blorp_StackOption_Int8;
typedef struct { int tag; int16_t value; } blorp_StackOption_Int16;
typedef struct { int tag; int32_t value; } blorp_StackOption_Int32;
typedef struct { int tag; long value; } blorp_StackOption_Int64;
typedef struct { int tag; uint8_t value; } blorp_StackOption_UInt8;
typedef struct { int tag; uint16_t value; } blorp_StackOption_UInt16;
typedef struct { int tag; uint32_t value; } blorp_StackOption_UInt32;
typedef struct { int tag; uint64_t value; } blorp_StackOption_UInt64;
typedef struct { int tag; double value; } blorp_StackOption_Float;
typedef struct { int tag; long value; } blorp_StackOption_Bool;
typedef struct { int tag; int32_t value; } blorp_StackOption_Char;
typedef struct { int tag; float value; } blorp_StackOption_Float32;
#ifdef __FLT16_MAX__
typedef struct { int tag; _Float16 value; } blorp_StackOption_Float16;
#endif

typedef struct {
    int tag;
    unsigned long release_mask;
    union {
        struct { void* field0; } Ok;
        struct { void* field0; } Err;
    } data;
} blorp_StackResult;

static inline void* blorp_stack_result_payload(blorp_StackResult res) {
    if (res.tag == 0) return res.data.Ok.field0;
    if (res.tag == 1) return res.data.Err.field0;
    return NULL;
}

static inline void blorp_stack_result_retain(blorp_StackResult res) {
    if ((res.release_mask & 1UL) == 0) return;
    void* payload = blorp_stack_result_payload(res);
    if (payload) blorp_retain(payload);
}

static inline blorp_StackResult blorp_stack_result_retain_value(blorp_StackResult res) {
    blorp_stack_result_retain(res);
    return res;
}

static inline void blorp_stack_result_release(blorp_StackResult res) {
    if ((res.release_mask & 1UL) == 0) return;
    void* payload = blorp_stack_result_payload(res);
    if (payload) blorp_release(payload);
}

static void blorp_stack_result_box_destroy(void* obj) {
    blorp_StackResult* res = (blorp_StackResult*)((char*)obj + sizeof(blorp_Object));
    blorp_stack_result_release(*res);
}

static inline void* blorp_box_stack_result(blorp_StackResult value) {
    void* boxed = blorp_alloc(sizeof(blorp_Object) + sizeof(blorp_StackResult));
    BLORP_SET_DESTRUCTOR(boxed, blorp_stack_result_box_destroy);
    memcpy((char*)boxed + sizeof(blorp_Object), &value, sizeof(blorp_StackResult));
    return boxed;
}

static inline blorp_StackResult blorp_stack_result_from_boxed_value(void* boxed) {
    if (!boxed) {
        return (blorp_StackResult){ .tag = 1, .release_mask = 0UL, .data.Err.field0 = NULL };
    }
    blorp_StackResult out =
        *(blorp_StackResult*)((char*)boxed + sizeof(blorp_Object));
    blorp_stack_result_retain(out);
    blorp_release(boxed);
    return out;
}

static inline blorp_StackOption_Int blorp_stack_option_int_none(void) {
    return (blorp_StackOption_Int){ .tag = BLORP_TAG_NONE, .value = 0 };
}

static inline blorp_StackOption_Int blorp_stack_option_int_some(long value) {
    return (blorp_StackOption_Int){ .tag = BLORP_TAG_SOME, .value = value };
}

#define BLORP_DEFINE_INT_STACK_OPTION(SUFFIX, NAME, CTYPE) \
static inline blorp_StackOption_##NAME blorp_stack_option_##SUFFIX##_none(void) { \
    return (blorp_StackOption_##NAME){ .tag = BLORP_TAG_NONE, .value = (CTYPE)0 }; \
} \
static inline blorp_StackOption_##NAME blorp_stack_option_##SUFFIX##_some(CTYPE value) { \
    return (blorp_StackOption_##NAME){ .tag = BLORP_TAG_SOME, .value = value }; \
}

BLORP_DEFINE_INT_STACK_OPTION(int8, Int8, int8_t)
BLORP_DEFINE_INT_STACK_OPTION(int16, Int16, int16_t)
BLORP_DEFINE_INT_STACK_OPTION(int32, Int32, int32_t)
BLORP_DEFINE_INT_STACK_OPTION(int64, Int64, long)
BLORP_DEFINE_INT_STACK_OPTION(uint8, UInt8, uint8_t)
BLORP_DEFINE_INT_STACK_OPTION(uint16, UInt16, uint16_t)
BLORP_DEFINE_INT_STACK_OPTION(uint32, UInt32, uint32_t)
BLORP_DEFINE_INT_STACK_OPTION(uint64, UInt64, uint64_t)

#undef BLORP_DEFINE_INT_STACK_OPTION

static inline blorp_StackOption_Float blorp_stack_option_float_none(void) {
    return (blorp_StackOption_Float){ .tag = BLORP_TAG_NONE, .value = 0.0 };
}

static inline blorp_StackOption_Float blorp_stack_option_float_some(double value) {
    return (blorp_StackOption_Float){ .tag = BLORP_TAG_SOME, .value = value };
}

static inline blorp_StackOption_Char blorp_stack_option_char_none(void) {
    return (blorp_StackOption_Char){ .tag = BLORP_TAG_NONE, .value = 0 };
}

static inline blorp_StackOption_Char blorp_stack_option_char_some(int32_t value) {
    return (blorp_StackOption_Char){ .tag = BLORP_TAG_SOME, .value = value };
}

static inline blorp_StackOption_Bool blorp_stack_option_bool_none(void) {
    return (blorp_StackOption_Bool){ .tag = BLORP_TAG_NONE, .value = 0 };
}

static inline blorp_StackOption_Bool blorp_stack_option_bool_some(long value) {
    return (blorp_StackOption_Bool){ .tag = BLORP_TAG_SOME, .value = value };
}

static inline blorp_StackOption_Float32 blorp_stack_option_float32_none(void) {
    return (blorp_StackOption_Float32){ .tag = BLORP_TAG_NONE, .value = 0.0f };
}

static inline blorp_StackOption_Float32 blorp_stack_option_float32_some(float value) {
    return (blorp_StackOption_Float32){ .tag = BLORP_TAG_SOME, .value = value };
}

#ifdef __FLT16_MAX__
static inline blorp_StackOption_Float16 blorp_stack_option_float16_none(void) {
    return (blorp_StackOption_Float16){ .tag = BLORP_TAG_NONE, .value = (_Float16)0.0 };
}

static inline blorp_StackOption_Float16 blorp_stack_option_float16_some(_Float16 value) {
    return (blorp_StackOption_Float16){ .tag = BLORP_TAG_SOME, .value = value };
}
#endif

static void blorp_option_destroy(void* obj) {
    blorp_Option* opt = (blorp_Option*)obj;
    if (opt->tag == BLORP_TAG_SOME && (opt->release_mask & 1UL) && opt->data.Some.field0) {
        blorp_release(opt->data.Some.field0);
    }
}

blorp_Option* blorp_option_some(void* value) {
    blorp_Option* opt = (blorp_Option*)blorp_alloc(sizeof(blorp_Option));
    BLORP_TAG(opt, "Option");
    BLORP_SET_DESTRUCTOR(opt, blorp_option_destroy);
    opt->release_mask = 0;
    opt->tag = BLORP_TAG_SOME;
    opt->data.Some.field0 = value;
    return opt;
}

// Pointer to the codegen-generated None singleton (set by __init_None constructor)
void* __blorp_none_singleton_ptr = NULL;

blorp_Option* blorp_option_none(void) {
    return (blorp_Option*)__blorp_none_singleton_ptr;
}

// Shape assertion: check tensor length matches expected, return nullable tensor.
// Source type is Option[Tensor], whose managed payload uses the nullable
// Option ABI: Some(tensor) is the retained tensor pointer, None is NULL.
blorp_Vector* blorp_assert_shape(blorp_Vector* tensor, long expected_len) {
    if (tensor && tensor->len == expected_len) {
        blorp_retain((blorp_Object*)tensor);
        return tensor;
    }
    return NULL;
}

blorp_Vector* blorp_assert_shape_nullable(blorp_Vector* tensor, long expected_len) {
    if (tensor && tensor->len == expected_len) {
        blorp_retain((blorp_Object*)tensor);
        return tensor;
    }
    return NULL;
}

// Option-returning integer division.
// This is the source-level checked_div ABI: Option[Int] is a stack struct,
// not the generic heap-allocated Option union.
blorp_StackOption_Int blorp_option_div_int(long a, long b) {
    if (b == 0 || (a == LONG_MIN && b == -1)) return blorp_stack_option_int_none();
    return blorp_stack_option_int_some(a / b);
}

// Option-returning integer modulo.
blorp_StackOption_Int blorp_option_mod_int(long a, long b) {
    if (b == 0) return blorp_stack_option_int_none();
    if (a == LONG_MIN && b == -1) return blorp_stack_option_int_some(0);
    return blorp_stack_option_int_some(a % b);
}

// Option equality - shallow void* comparison (works for Int, Bool, Char)
long blorp_option_eq(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Option* oa = (blorp_Option*)a;
    blorp_Option* ob = (blorp_Option*)b;
    if (oa->tag != ob->tag) return 0;
    if (oa->tag == BLORP_TAG_NONE) return 1;
    return (long)(oa->data.Some.field0 == ob->data.Some.field0);
}

// Option equality for String element type
long blorp_option_eq_string(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Option* oa = (blorp_Option*)a;
    blorp_Option* ob = (blorp_Option*)b;
    if (oa->tag != ob->tag) return 0;
    if (oa->tag == BLORP_TAG_NONE) return 1;
    return blorp_string_eq(oa->data.Some.field0, ob->data.Some.field0);
}

// Option equality for Float element type
long blorp_option_eq_float(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Option* oa = (blorp_Option*)a;
    blorp_Option* ob = (blorp_Option*)b;
    if (oa->tag != ob->tag) return 0;
    if (oa->tag == BLORP_TAG_NONE) return 1;
    double da, db;
    memcpy(&da, &oa->data.Some.field0, sizeof(double));
    memcpy(&db, &ob->data.Some.field0, sizeof(double));
    return (long)(da == db);
}

// ============================================================================
// Result Support
// ============================================================================

// Result-compatible struct for runtime functions
// Layout matches generated Result type (blorp_Object header for ARC compatibility)
typedef struct {
    blorp_Object header;
    int tag;
    unsigned long release_mask;
    union {
        struct { void* field0; } Ok;
        struct { void* field0; } Err;
    } data;
} blorp_Result;

#define BLORP_TAG_OK 0
#define BLORP_TAG_ERR 1

static void blorp_result_destroy(void* obj) {
    blorp_Result* res = (blorp_Result*)obj;
    if (res->tag == BLORP_TAG_OK) {
        if ((res->release_mask & 1UL) && res->data.Ok.field0) blorp_release(res->data.Ok.field0);
    } else if (res->tag == BLORP_TAG_ERR) {
        if ((res->release_mask & 1UL) && res->data.Err.field0) blorp_release(res->data.Err.field0);
    }
}

static inline blorp_StackResult blorp_stack_result_from_boxed(blorp_Result* res) {
    if (!res) {
        return (blorp_StackResult){ .tag = BLORP_TAG_ERR, .release_mask = 0UL, .data.Err.field0 = NULL };
    }
    blorp_StackResult out;
    out.tag = res->tag;
    out.release_mask = res->release_mask & 1UL;
    if (res->tag == BLORP_TAG_OK) {
        out.data.Ok.field0 = res->data.Ok.field0;
        if (out.release_mask && out.data.Ok.field0) blorp_retain(out.data.Ok.field0);
    } else {
        out.data.Err.field0 = res->data.Err.field0;
        if (out.release_mask && out.data.Err.field0) blorp_retain(out.data.Err.field0);
    }
    blorp_release(res);
    return out;
}

blorp_Result* blorp_result_ok(void* value) {
    blorp_Result* res = (blorp_Result*)blorp_alloc(sizeof(blorp_Result));
    BLORP_TAG(res, "Result");
    BLORP_SET_DESTRUCTOR(res, blorp_result_destroy);
    res->release_mask = 0;
    res->tag = BLORP_TAG_OK;
    res->data.Ok.field0 = value;
    return res;
}

blorp_Result* blorp_result_err(void* value) {
    blorp_Result* res = (blorp_Result*)blorp_alloc(sizeof(blorp_Result));
    BLORP_TAG(res, "Result");
    BLORP_SET_DESTRUCTOR(res, blorp_result_destroy);
    res->release_mask = 0;
    res->tag = BLORP_TAG_ERR;
    res->data.Err.field0 = value;
    return res;
}

// ============================================================================
// ConcurrencyError type — used by concurrent: blocks
// ============================================================================

typedef struct {
    blorp_Object header;
    int tag;
    unsigned long release_mask;
    union {
        char Timeout;
        struct { void* field0; } TaskFailed;
        char Cancelled;
    } data;
} blorp_ConcurrencyError;

// Tag names match the parent-scoped convention emitted by core_emit for
// user-visible pattern matching on [ConcurrencyError]. The unscoped aliases
// keep the runtime implementation readable.
#define TAG_ConcurrencyError_Timeout 0
#define TAG_ConcurrencyError_TaskFailed 1
#define TAG_ConcurrencyError_Cancelled 2
#define TAG_Timeout TAG_ConcurrencyError_Timeout
#define TAG_TaskFailed TAG_ConcurrencyError_TaskFailed
#define TAG_Cancelled TAG_ConcurrencyError_Cancelled

// Timeout singleton — immortal, never freed
static blorp_ConcurrencyError __blorp_Timeout_instance;
    __attribute__((constructor)) static void __init_blorp_Timeout(void) {
    atomic_store_explicit(&__blorp_Timeout_instance.header.refcount, BLORP_IMMORTAL_REFCOUNT, memory_order_relaxed);
    __blorp_Timeout_instance.header.alloc_class = BLORP_ALLOC_CLASS_DIRECT;
    __blorp_Timeout_instance.header.destructor_id = 0;
    __blorp_Timeout_instance.tag = TAG_Timeout;
}
#define blorp_Timeout ((blorp_ConcurrencyError*)&__blorp_Timeout_instance)

// Cancelled singleton — immortal, never freed
static blorp_ConcurrencyError __blorp_Cancelled_instance;
    __attribute__((constructor)) static void __init_blorp_Cancelled(void) {
    atomic_store_explicit(&__blorp_Cancelled_instance.header.refcount, BLORP_IMMORTAL_REFCOUNT, memory_order_relaxed);
    __blorp_Cancelled_instance.header.alloc_class = BLORP_ALLOC_CLASS_DIRECT;
    __blorp_Cancelled_instance.header.destructor_id = 0;
    __blorp_Cancelled_instance.tag = TAG_Cancelled;
}
#define blorp_Cancelled ((blorp_ConcurrencyError*)&__blorp_Cancelled_instance)

blorp_ConcurrencyError* blorp_TaskFailed(void* msg) {
    blorp_ConcurrencyError* v = (blorp_ConcurrencyError*)blorp_alloc(sizeof(blorp_ConcurrencyError));
    v->tag = TAG_TaskFailed;
    v->data.TaskFailed.field0 = msg;
    return v;
}

// Result equality - shallow void* comparison (works for Int, Bool, Char)
long blorp_result_eq(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Result* ra = (blorp_Result*)a;
    blorp_Result* rb = (blorp_Result*)b;
    if (ra->tag != rb->tag) return 0;
    if (ra->tag == BLORP_TAG_OK) return (long)(ra->data.Ok.field0 == rb->data.Ok.field0);
    // Err is always String in practice — use string comparison
    return blorp_string_eq(ra->data.Err.field0, rb->data.Err.field0);
}

// Result equality for String Ok and/or Err element types
long blorp_result_eq_string(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Result* ra = (blorp_Result*)a;
    blorp_Result* rb = (blorp_Result*)b;
    if (ra->tag != rb->tag) return 0;
    if (ra->tag == BLORP_TAG_OK) return blorp_string_eq(ra->data.Ok.field0, rb->data.Ok.field0);
    return blorp_string_eq(ra->data.Err.field0, rb->data.Err.field0);
}

// Result equality for Float Ok element type (Err is still string comparison)
long blorp_result_eq_float(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Result* ra = (blorp_Result*)a;
    blorp_Result* rb = (blorp_Result*)b;
    if (ra->tag != rb->tag) return 0;
    if (ra->tag == BLORP_TAG_OK) {
        double da, db;
        memcpy(&da, &ra->data.Ok.field0, sizeof(double));
        memcpy(&db, &rb->data.Ok.field0, sizeof(double));
        return (long)(da == db);
    }
    // Err is always String in practice — use string comparison
    return blorp_string_eq(ra->data.Err.field0, rb->data.Err.field0);
}

// Result to_string helpers
// Helper: format "PREFIX(VALUE)" where value is a blorp_String
static blorp_String* blorp_result_fmt_string(const char* prefix, blorp_String* inner) {
    size_t plen = strlen(prefix);
    size_t ilen = inner ? inner->len : 0;
    size_t total = plen + ilen + 1; // +1 for closing paren
    char* buf = blorp_malloc_checked(total + 1);
    memcpy(buf, prefix, plen);
    if (inner) memcpy(buf + plen, inner->data, ilen);
    buf[plen + ilen] = ')';
    buf[total] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, total);
    free(buf);
    return result;
}

// Result[Int, Int] and similar all-primitive
blorp_String* blorp_result_to_string_int(void* r) {
    blorp_Result* res = (blorp_Result*)r;
    char buf[64];
    int len;
    if (res->tag == BLORP_TAG_OK) {
        len = snprintf(buf, sizeof(buf), "Ok(%ld)", (long)res->data.Ok.field0);
    } else {
        len = snprintf(buf, sizeof(buf), "Err(%ld)", (long)res->data.Err.field0);
    }
    return blorp_string_from_buf(buf, len);
}

// Result[T, String] where Ok is Int, Err is String
blorp_String* blorp_result_to_string_int_string(void* r) {
    blorp_Result* res = (blorp_Result*)r;
    if (res->tag == BLORP_TAG_OK) {
        char buf[64];
        int len = snprintf(buf, sizeof(buf), "Ok(%ld)", (long)res->data.Ok.field0);
        return blorp_string_from_buf(buf, len);
    } else {
        return blorp_result_fmt_string("Err(", (blorp_String*)res->data.Err.field0);
    }
}

// Result[String, T] where Ok is String, Err is Int
blorp_String* blorp_result_to_string_string_int(void* r) {
    blorp_Result* res = (blorp_Result*)r;
    if (res->tag == BLORP_TAG_OK) {
        return blorp_result_fmt_string("Ok(", (blorp_String*)res->data.Ok.field0);
    } else {
        char buf[64];
        int len = snprintf(buf, sizeof(buf), "Err(%ld)", (long)res->data.Err.field0);
        return blorp_string_from_buf(buf, len);
    }
}

// Result[String, String]
blorp_String* blorp_result_to_string_string_string(void* r) {
    blorp_Result* res = (blorp_Result*)r;
    if (res->tag == BLORP_TAG_OK) {
        return blorp_result_fmt_string("Ok(", (blorp_String*)res->data.Ok.field0);
    } else {
        return blorp_result_fmt_string("Err(", (blorp_String*)res->data.Err.field0);
    }
}

// (removed blorp_list_get_opt — now IR intrinsic)

// Bounds-checked string character access returning stack Option[Char]
blorp_StackOption_Char blorp_string_get_opt(const blorp_String* s, long index) {
    if (!s || index < 0 || index >= s->len) {
        return blorp_stack_option_char_none();
    }
    return blorp_stack_option_char_some((int32_t)(unsigned char)s->data[index]);
}

// Safe string-to-int parsing: returns stack Option[Int]
blorp_StackOption_Int blorp_parse_int(blorp_String* s) {
    if (!s || s->len == 0) return blorp_stack_option_int_none();
    char* end;
    long val = strtol(s->data, &end, 10);
    if (end == s->data || *end != '\0') return blorp_stack_option_int_none();
    return blorp_stack_option_int_some(val);
}

// Safe string-to-float parsing: returns stack Option[Float]
blorp_StackOption_Float blorp_parse_float(blorp_String* s) {
    if (!s || s->len == 0) return blorp_stack_option_float_none();
    char* end;
    double val = strtod(s->data, &end);
    if (end == s->data || *end != '\0') return blorp_stack_option_float_none();
    return blorp_stack_option_float_some(val);
}

// Helper to copy list (for COW semantics)
static blorp_List* blorp_list_copy(blorp_List* src) {
    if (!src) return blorp_list_new(4);
    size_t stride = blorp_list_stride(src);
    blorp_List* list = (blorp_List*)blorp_alloc(blorp_checked_add(sizeof(blorp_List), blorp_checked_mul(src->capacity, stride)));
    list->len = src->len;
    list->capacity = src->capacity;
    list->elem_release = src->elem_release;
    list->elem_size = src->elem_size;
    list->storage_mode = src->storage_mode;
    BLORP_SET_DESTRUCTOR(list, blorp_list_destroy);
    memcpy(list->data, src->data, src->len * stride);
    // Retain all elements — the copy shares ownership with the original
    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release) {
        for (long i = 0; i < list->len; i++) {
            if (list->data[i]) blorp_retain(list->data[i]);
        }
    }
    return list;
}

// Helper to copy list with extra capacity (for COW + growth)
static blorp_List* blorp_list_copy_with_capacity(blorp_List* src, long new_capacity) {
    if (!src) return blorp_list_new(new_capacity);
    size_t stride = blorp_list_stride(src);
    blorp_List* list = (blorp_List*)blorp_alloc(blorp_checked_add(sizeof(blorp_List), blorp_checked_mul(new_capacity, stride)));
    list->len = src->len;
    list->capacity = new_capacity;
    list->elem_release = src->elem_release;
    list->elem_size = src->elem_size;
    list->storage_mode = src->storage_mode;
    BLORP_SET_DESTRUCTOR(list, blorp_list_destroy);
    memcpy(list->data, src->data, src->len * stride);
    // Retain all elements — the copy shares ownership with the original
    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release) {
        for (long i = 0; i < list->len; i++) {
            if (list->data[i]) blorp_retain(list->data[i]);
        }
    }
    return list;
}

// Copy a borrowed source span into destination slots that have not been
// initialized yet. Pointer-backed owning lists retain the copied elements;
// inline storage can be copied as raw bytes because inline list elements are
// unmanaged by construction.
void blorp_list_copy_span_uninit(blorp_List* dst, long dst_start, blorp_List* src, long src_start, long count) {
    if (!dst || !src || count <= 0) return;

    if (dst_start < 0) {
        long skip = -dst_start;
        dst_start = 0;
        src_start += skip;
        count -= skip;
    }
    if (src_start < 0) {
        long skip = -src_start;
        src_start = 0;
        dst_start += skip;
        count -= skip;
    }
    if (count <= 0 || src_start >= src->len || dst_start >= dst->capacity) return;

    long src_avail = src->len - src_start;
    long dst_avail = dst->capacity - dst_start;
    if (count > src_avail) count = src_avail;
    if (count > dst_avail) count = dst_avail;
    if (count <= 0) return;

    if (dst->storage_mode == BLORP_LIST_STORAGE_INLINE &&
        src->storage_mode == BLORP_LIST_STORAGE_INLINE &&
        dst->elem_size == src->elem_size) {
        size_t stride = blorp_list_stride(src);
        memmove((char*)dst->data + dst_start * stride,
                (char*)src->data + src_start * stride,
                (size_t)count * stride);
        return;
    }

    if (dst->storage_mode == BLORP_LIST_STORAGE_POINTER &&
        src->storage_mode == BLORP_LIST_STORAGE_POINTER) {
        memmove(&dst->data[dst_start], &src->data[src_start],
                (size_t)count * sizeof(void*));
        if (dst->elem_release) {
            for (long i = 0; i < count; i++) {
                void* value = dst->data[dst_start + i];
                if (value) blorp_retain(value);
            }
        }
        return;
    }

    for (long i = 0; i < count; i++) {
        void* value = blorp_list_get(src, src_start + i);
        if (dst->storage_mode == BLORP_LIST_STORAGE_POINTER &&
            src->storage_mode == BLORP_LIST_STORAGE_POINTER &&
            dst->elem_release && value) {
            blorp_retain(value);
        }
        blorp_list_store_raw(dst, dst_start + i, value);
    }
}

static void blorp_list_reverse_slots_inplace(blorp_List* list) {
    if (!list || list->len <= 1) return;

    size_t stride = blorp_list_stride(list);
    unsigned char stack_tmp[256];
    unsigned char* tmp = stack_tmp;
    if (stride > sizeof(stack_tmp)) {
        tmp = (unsigned char*)malloc(stride);
        if (!tmp) {
            fprintf(stderr, "blorp: out of memory (requested %zu bytes)\n", stride);
            exit(1);
        }
    }

    char* data = (char*)list->data;
    for (long i = 0, j = list->len - 1; i < j; i++, j--) {
        void* a = data + i * stride;
        void* b = data + j * stride;
        memcpy(tmp, a, stride);
        memcpy(a, b, stride);
        memcpy(b, tmp, stride);
    }

    if (tmp != stack_tmp) free(tmp);
}

// Consume one owned list reference and return an owned reversed list. Unique
// inputs reverse in place; shared inputs allocate a reversed copy and release
// the consumed owner after copying.
blorp_List* blorp_list_reverse_owned(blorp_List* list) {
    if (!list) return blorp_list_new(0);
    long n = list->len;
    if (n <= 1) return list;

    if (blorp_is_unique(list)) {
        blorp_list_reverse_slots_inplace(list);
        return list;
    }

    void (*elem_release)(void*) = list->elem_release;
    blorp_List* result = blorp_list_new_layout(n, list->storage_mode, list->elem_size);
    if (result->storage_mode == BLORP_LIST_STORAGE_POINTER && elem_release) {
        blorp_list_init_elem_release(result, elem_release);
    }

    if (result->storage_mode == BLORP_LIST_STORAGE_INLINE &&
        list->storage_mode == BLORP_LIST_STORAGE_INLINE &&
        result->elem_size == list->elem_size) {
        size_t stride = blorp_list_stride(list);
        char* dst = (char*)result->data;
        char* src = (char*)list->data;
        for (long i = 0; i < n; i++) {
            memcpy(dst + i * stride, src + (n - 1 - i) * stride, stride);
        }
    } else if (result->storage_mode == BLORP_LIST_STORAGE_POINTER &&
               list->storage_mode == BLORP_LIST_STORAGE_POINTER) {
        for (long i = 0; i < n; i++) {
            void* value = list->data[n - 1 - i];
            if (elem_release && value) blorp_retain(value);
            result->data[i] = value;
        }
    } else {
        for (long i = 0; i < n; i++) {
            void* value = blorp_list_get(list, n - 1 - i);
            if (result->storage_mode == BLORP_LIST_STORAGE_POINTER &&
                list->storage_mode == BLORP_LIST_STORAGE_POINTER &&
                elem_release && value) {
                blorp_retain(value);
            }
            blorp_list_store_raw(result, i, value);
        }
    }

    result->len = n;
    blorp_release(list);
    return result;
}

// FFI copy: create independent shallow copy of a list (refcount = 1, elements retained)
blorp_List* blorp_list_copy_ffi(blorp_List* src) {
    return blorp_list_copy(src);
}

// IR intrinsic: COW check — if shared, return a copy; if unique, return as-is.
// The caller is responsible for releasing the original if it was copied.
blorp_List* blorp_list_cow(blorp_List* list) {
    if (!list) return blorp_list_new(4);
    if (blorp_is_unique(list)) return list;
    blorp_List* copy = blorp_list_copy(list);
    blorp_release(list);
    return copy;
}

// IR intrinsic: COW + ensure capacity >= min_cap.
// Returns a unique list with at least min_cap slots.
blorp_List* blorp_list_ensure_capacity(blorp_List* list, long min_cap) {
    if (!list) return blorp_list_new(min_cap);
    if (blorp_is_unique(list) && list->capacity >= min_cap) return list;
    long new_cap = list->capacity;
    if (new_cap < 4) new_cap = 4;
    while (new_cap < min_cap) new_cap *= 2;
    blorp_List* copy = blorp_list_copy_with_capacity(list, new_cap);
    blorp_release(list);
    return copy;
}

// IR intrinsic: consume a dead list owner and return an empty list allocation.
// Reuses storage only when the owner is unique; otherwise it releases the caller's
// reference and allocates fresh empty storage.
blorp_List* blorp_list_reuse_alloc(blorp_List* list, long min_cap) {
    if (!list) return blorp_list_new(min_cap);

    void (*elem_release)(void*) = list->elem_release;
    uint8_t storage_mode = list->storage_mode;
    int16_t elem_size = list->elem_size;
    if (!blorp_is_unique(list)) {
        blorp_release(list);
        blorp_List* fresh = blorp_list_new_layout(min_cap, storage_mode, elem_size);
        if (fresh->storage_mode == BLORP_LIST_STORAGE_POINTER) fresh->elem_release = elem_release;
        return fresh;
    }

    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && elem_release) {
        for (long i = 0; i < list->len; i++) {
            if (list->data[i]) {
                elem_release(list->data[i]);
                list->data[i] = NULL;
            }
        }
    }
    list->len = 0;

    if (list->capacity >= min_cap) return list;

    blorp_List* fresh = blorp_list_new_layout(min_cap, storage_mode, elem_size);
    if (fresh->storage_mode == BLORP_LIST_STORAGE_POINTER) fresh->elem_release = elem_release;
    blorp_release(list);
    return fresh;
}

void blorp_list_release_elem(blorp_List* list, long index) {
    if (!list || list->storage_mode != BLORP_LIST_STORAGE_POINTER || !list->elem_release) return;
    if (index < 0 || index >= list->len) return;
    if (list->data[index]) list->elem_release(list->data[index]);
}

void blorp_list_retain_for(blorp_List* list, void* value) {
    if (!list || list->storage_mode != BLORP_LIST_STORAGE_POINTER || !list->elem_release || !value) return;
    blorp_retain(value);
}

// Producer/fusion handoff helpers.
// The generated handoff body writes through handoff store helpers and calls
// finish exactly once after all source reads have completed.
blorp_List* blorp_list_handoff_begin_borrow(long min_cap, void (*elem_release)(void*), uint8_t storage_mode, int16_t elem_size) {
    blorp_List* result = blorp_list_new_layout(min_cap, storage_mode, elem_size);
    if (elem_release && result->storage_mode == BLORP_LIST_STORAGE_POINTER) blorp_list_init_elem_release(result, elem_release);
    return result;
}

blorp_List* blorp_list_handoff_begin_reuse(blorp_List* source, long min_cap, void (*elem_release)(void*), uint8_t storage_mode, int16_t elem_size, bool* reused_out) {
    bool reused = source
        && blorp_is_unique(source)
        && source->capacity >= min_cap
        && source->elem_release == elem_release
        && source->storage_mode == storage_mode
        && source->elem_size == elem_size;
    if (reused_out) *reused_out = reused;

    if (reused) return source;

    blorp_List* result = blorp_list_new_layout(min_cap, storage_mode, elem_size);
    if (elem_release && result->storage_mode == BLORP_LIST_STORAGE_POINTER) blorp_list_init_elem_release(result, elem_release);
    return result;
}

void blorp_list_handoff_set_owned(blorp_List* list, long index, void* value) {
    if (!list) return;
    if (index < 0 || index >= list->capacity) {
        if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release && value) list->elem_release(value);
        return;
    }
    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release && index >= 0 && index < list->len && list->data[index]) {
        list->elem_release(list->data[index]);
        list->data[index] = NULL;
    }
    blorp_list_store_raw(list, index, value);
}

void blorp_list_handoff_set_source_slot(blorp_List* result, long out_index, blorp_List* source, long source_index) {
    if (!result || !source) return;
    if (out_index < 0 || out_index >= result->capacity) return;
    if (source_index < 0 || source_index >= source->len) return;

    if (result == source) {
        if (out_index == source_index) return;

        if (source->storage_mode == BLORP_LIST_STORAGE_POINTER) {
            void* value = source->data[source_index];
            if (out_index < source->len && source->elem_release && source->data[out_index]) {
                source->elem_release(source->data[out_index]);
            }
            source->data[out_index] = value;
            source->data[source_index] = NULL;
        } else {
            size_t stride = blorp_list_stride(source);
            memmove((char*)source->data + out_index * stride,
                    (char*)source->data + source_index * stride,
                    stride);
        }
        return;
    }

    void* value = blorp_list_get(source, source_index);
    if (result->storage_mode == BLORP_LIST_STORAGE_POINTER && result->elem_release) {
        if (value) blorp_retain(value);
        if (out_index < result->len && result->data[out_index]) {
            result->elem_release(result->data[out_index]);
        }
    }
    blorp_list_store_raw(result, out_index, value);
}

void blorp_list_handoff_finish(blorp_List* result, long out_len, long old_len, bool reused, blorp_List* consumed_source) {
    if (!result) {
        if (consumed_source) blorp_release(consumed_source);
        return;
    }

    if (out_len < 0) out_len = 0;
    if (out_len > result->capacity) out_len = result->capacity;
    if (old_len < 0) old_len = 0;
    if (old_len > result->capacity) old_len = result->capacity;

    if (reused && result->storage_mode == BLORP_LIST_STORAGE_POINTER && result->elem_release) {
        for (long i = out_len; i < old_len; i++) {
            if (result->data[i]) {
                result->elem_release(result->data[i]);
                result->data[i] = NULL;
            }
        }
    }

    result->len = out_len;
    if (!reused && consumed_source && consumed_source != result) blorp_release(consumed_source);
}

blorp_List* blorp_list_append(blorp_List* list, void* element) {
    if (!list) list = blorp_list_new(4);

    // COW: if shared, copy the list first
    if (!blorp_is_unique(list)) {
        // Need capacity for at least one more element
        long new_cap = list->len >= list->capacity ? list->capacity * 2 : list->capacity;
        blorp_List* copy = blorp_list_copy_with_capacity(list, new_cap);
        blorp_release(list);
        list = copy;
    } else if (list->len >= list->capacity) {
        // Unique but need more capacity - reallocate (transfer ownership, no element retain)
        long new_cap = list->capacity * 2;
        size_t stride = blorp_list_stride(list);
        blorp_List* new_list = (blorp_List*)blorp_alloc(blorp_checked_add(sizeof(blorp_List), blorp_checked_mul(new_cap, stride)));
        new_list->len = list->len;
        new_list->capacity = new_cap;
        new_list->elem_release = list->elem_release;
        new_list->elem_size = list->elem_size;
        new_list->storage_mode = list->storage_mode;
        BLORP_SET_DESTRUCTOR(new_list, blorp_list_destroy);
        memcpy(new_list->data, list->data, list->len * stride);
        // Transfer ownership: suppress element release in old list's destructor
        list->elem_release = NULL;
        blorp_release(list);
        list = new_list;
    }
    // Now list is unique and has capacity - safe to mutate in place
    if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release && element) blorp_retain(element);
    blorp_list_store_raw(list, list->len++, element);
    return list;
}

// Append with ownership transfer — does NOT auto-retain.
// Used by codegen when the element is a fresh allocation (refcount already 1).
// Sets elem_release if not already set so destructor properly cleans up.
blorp_List* blorp_list_append_owned(blorp_List* list, void* element) {
    if (!list) list = blorp_list_new(4);

    // COW: if shared, copy the list first
    if (!blorp_is_unique(list)) {
        long new_cap = list->len >= list->capacity ? list->capacity * 2 : list->capacity;
        blorp_List* copy = blorp_list_copy_with_capacity(list, new_cap);
        blorp_release(list);
        list = copy;
    } else if (list->len >= list->capacity) {
        long new_cap = list->capacity * 2;
        size_t stride = blorp_list_stride(list);
        blorp_List* new_list = (blorp_List*)blorp_alloc(blorp_checked_add(sizeof(blorp_List), blorp_checked_mul(new_cap, stride)));
        new_list->len = list->len;
        new_list->capacity = new_cap;
        new_list->elem_release = list->elem_release;
        new_list->elem_size = list->elem_size;
        new_list->storage_mode = list->storage_mode;
        BLORP_SET_DESTRUCTOR(new_list, blorp_list_destroy);
        memcpy(new_list->data, list->data, list->len * stride);
        list->elem_release = NULL;
        blorp_release(list);
        list = new_list;
    }
    // No retain — ownership transferred from caller
    blorp_list_store_raw(list, list->len++, element);
    return list;
}


// (removed blorp_list_set_releasing — now IR intrinsic)
// (removed blorp_list_set_inplace — now IR intrinsic)
// (removed blorp_list_set_releasing_inplace — now IR intrinsic)
// (removed blorp_list_insert_inplace — now IR intrinsic)
// (removed blorp_list_remove_inplace — now IR intrinsic)

// Build a list from variadic arguments (used by list literals)
blorp_List* blorp_list_build(long count, ...) {
    blorp_List* list = blorp_list_new(count > 0 ? count : 4);
    va_list args;
    va_start(args, count);
    for (long i = 0; i < count; i++) {
        void* elem = va_arg(args, void*);
        // Note: elem_release is NULL at this point (just created by blorp_list_new).
        // Codegen sets elem_release AFTER blorp_list_build returns.
        // Elements passed to build are freshly constructed — no retain needed here.
        blorp_list_store_raw(list, i, elem);
    }
    va_end(args);
    list->len = count;
    return list;
}

// ============================================================================
// Vector Operations
// ============================================================================

// new(value, size) — create a 1D vector filled with a value
blorp_Vector* blorp_vector_new_fill(void* value, long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = sizeof(void*);
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    for (long i = 0; i < size; i++) arr->data[i] = value;
    return arr;
}

// new(value, rows, cols) — create a 2D matrix filled with a value
blorp_Vector* blorp_matrix_new_fill(void* value, long rows, long cols) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = rows;
    arr->capacity = total;
    arr->elem_release = NULL;
    arr->elem_size = sizeof(void*);
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    for (long i = 0; i < total; i++) arr->data[i] = value;
    return arr;
}

// N-D tensor constructors: tensor3(value, d1, d2, d3), etc.
// len = first dim (for iteration), capacity = total elements
blorp_Vector* blorp_tensor3_new(void* value, long d1, long d2, long d3) {
    if (d1 < 0) d1 = 0; if (d2 < 0) d2 = 0; if (d3 < 0) d3 = 0;
    long total = (long)blorp_checked_mul(d1, blorp_checked_mul(d2, d3));
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = d1;
    arr->capacity = total;
    arr->elem_release = NULL;
    arr->elem_size = sizeof(void*);
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    for (long i = 0; i < total; i++) arr->data[i] = value;
    return arr;
}

blorp_Vector* blorp_tensor4_new(void* value, long d1, long d2, long d3, long d4) {
    if (d1 < 0) d1 = 0; if (d2 < 0) d2 = 0; if (d3 < 0) d3 = 0; if (d4 < 0) d4 = 0;
    long total = (long)blorp_checked_mul(blorp_checked_mul(d1, d2), blorp_checked_mul(d3, d4));
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = d1;
    arr->capacity = total;
    arr->elem_release = NULL;
    arr->elem_size = sizeof(void*);
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    for (long i = 0; i < total; i++) arr->data[i] = value;
    return arr;
}

blorp_Vector* blorp_tensor5_new(void* value, long d1, long d2, long d3, long d4, long d5) {
    if (d1 < 0) d1 = 0; if (d2 < 0) d2 = 0; if (d3 < 0) d3 = 0; if (d4 < 0) d4 = 0; if (d5 < 0) d5 = 0;
    long total = (long)blorp_checked_mul(blorp_checked_mul(d1, blorp_checked_mul(d2, d3)), blorp_checked_mul(d4, d5));
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = d1;
    arr->capacity = total;
    arr->elem_release = NULL;
    arr->elem_size = sizeof(void*);
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    for (long i = 0; i < total; i++) arr->data[i] = value;
    return arr;
}

blorp_Vector* blorp_vector_new(long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(void*))));
    BLORP_TAG(arr, "Vector");
    arr->len = size;
    arr->capacity = size;  /* Fixed size for arrays */
    arr->elem_release = NULL;
    arr->elem_size = 8;
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    memset(arr->data, 0, size * sizeof(void*));
    return arr;
}

// Like blorp_vector_new but skips memset — caller MUST fill all elements
blorp_Vector* blorp_vector_new_noinit(long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(void*))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = 8;
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    return arr;
}

blorp_Vector* blorp_tensor_new(long first_dim, long total_capacity) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total_capacity, sizeof(void*))));
    arr->len = first_dim;
    arr->capacity = total_capacity;
    arr->elem_release = NULL;
    arr->elem_size = 8;
    arr->storage_mode = BLORP_VECTOR_STORAGE_POINTER;
    memset(arr->data, 0, total_capacity * sizeof(void*));
    return arr;
}

// Dimension peeling: extract slice i from a 2D+ tensor as a sub-tensor (copy).
// sub_len is the first dimension of the result: for 2D→1D it equals capacity/len (cols),
// for 3D→2D it's the second dimension. Codegen passes the known dimension from the type.
// The returned tensor has len=sub_len, capacity=elems_per_slice.
// If the parent has elem_release, each copied element is retained.
blorp_Vector* blorp_tensor_peel_row(blorp_Vector* tensor, long row_idx, long sub_len) {
    if (!tensor || row_idx < 0 || row_idx >= tensor->len) return blorp_vector_new(0);
    long elems_per_slice = tensor->len > 0 ? tensor->capacity / tensor->len : 0;
    if (elems_per_slice <= 0) return blorp_vector_new(0);
    long byte_size = elems_per_slice * sizeof(void*);
    // For Float32, use 4-byte elements
    if (tensor->storage_mode == BLORP_VECTOR_STORAGE_F32
        && tensor->elem_size == (int16_t)sizeof(float)) {
        blorp_Vector* row = (blorp_Vector*)blorp_alloc(
            blorp_checked_add(sizeof(blorp_Vector), elems_per_slice * sizeof(float)));
        row->len = sub_len;
        row->capacity = elems_per_slice;
        row->elem_release = NULL;
        row->elem_size = 4;
        row->storage_mode = BLORP_VECTOR_STORAGE_F32;
        memcpy(row->data, (float*)tensor->data + row_idx * elems_per_slice, elems_per_slice * sizeof(float));
        return row;
    }
    blorp_Vector* row = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), byte_size));
    row->len = sub_len;
    row->capacity = elems_per_slice;
    row->elem_release = tensor->elem_release;
    row->elem_size = tensor->elem_size;
    row->storage_mode = tensor->storage_mode;
    if (row->elem_release) {
        BLORP_SET_DESTRUCTOR(row, blorp_vector_destroy);
    }
    memcpy(row->data, tensor->data + row_idx * elems_per_slice, byte_size);
    // Retain each element for the new copy
    if (row->elem_release) {
        for (long i = 0; i < elems_per_slice; i++) {
            if (row->data[i]) blorp_retain(row->data[i]);
        }
    }
    return row;
}

// Float64 raw constructors — 8 bytes per element, but tagged so reads never
// confuse raw bits with boxed Float objects.
blorp_Vector* blorp_vector_new_f64(long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(double))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(double);
    arr->storage_mode = BLORP_VECTOR_STORAGE_F64;
    memset(arr->data, 0, size * sizeof(double));
    return arr;
}

static blorp_Vector* blorp_vector_new_f64_noinit(long size) {
    if (size < 0) size = 0;
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(double))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(double);
    arr->storage_mode = BLORP_VECTOR_STORAGE_F64;
    return arr;
}

blorp_Vector* blorp_tensor_new_f64(long first_dim, long total_capacity) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total_capacity, sizeof(double))));
    arr->len = first_dim;
    arr->capacity = total_capacity;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(double);
    arr->storage_mode = BLORP_VECTOR_STORAGE_F64;
    memset(arr->data, 0, total_capacity * sizeof(double));
    return arr;
}

// Int64 raw constructors — 8 bytes per element, tagged so Int tensors can
// be treated as typed numeric storage instead of generic pointer slots.
blorp_Vector* blorp_vector_new_i64(long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(long))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(long);
    arr->storage_mode = BLORP_VECTOR_STORAGE_I64;
    memset(arr->data, 0, size * sizeof(long));
    return arr;
}

static blorp_Vector* blorp_vector_new_i64_noinit(long size) {
    if (size < 0) size = 0;
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(long))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(long);
    arr->storage_mode = BLORP_VECTOR_STORAGE_I64;
    return arr;
}

blorp_Vector* blorp_tensor_new_i64(long first_dim, long total_capacity) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total_capacity, sizeof(long))));
    arr->len = first_dim;
    arr->capacity = total_capacity;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)sizeof(long);
    arr->storage_mode = BLORP_VECTOR_STORAGE_I64;
    memset(arr->data, 0, total_capacity * sizeof(long));
    return arr;
}

blorp_Vector* blorp_vector_new_fill_i64(long value, long size) {
    if (size < 0) size = 0;
    blorp_Vector* arr = blorp_vector_new_i64(size);
    for (long i = 0; i < size; i++) {
        ((long*)arr->data)[i] = value;
    }
    return arr;
}

blorp_Vector* blorp_matrix_new_fill_i64(long value, long rows, long cols) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = blorp_tensor_new_i64(rows, total);
    for (long i = 0; i < total; i++) {
        ((long*)arr->data)[i] = value;
    }
    return arr;
}

// Float32 packed constructors — 4 bytes per element instead of 8
blorp_Vector* blorp_vector_new_f32(long size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(float))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = 4;
    arr->storage_mode = BLORP_VECTOR_STORAGE_F32;
    memset(arr->data, 0, size * sizeof(float));
    return arr;
}

static blorp_Vector* blorp_vector_new_f32_noinit(long size) {
    if (size < 0) size = 0;
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, sizeof(float))));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = 4;
    arr->storage_mode = BLORP_VECTOR_STORAGE_F32;
    return arr;
}

// Inline struct storage: each element is `elem_byte_size` bytes, stored contiguously.
// No per-element heap allocation — structs are copied by value.
blorp_Vector* blorp_vector_new_sized(long size, long elem_byte_size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(size, elem_byte_size)));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)elem_byte_size;
    arr->storage_mode = BLORP_VECTOR_STORAGE_INLINE;
    memset(arr->data, 0, size * elem_byte_size);
    return arr;
}

blorp_Vector* blorp_tensor_new_sized(long first_dim, long total_capacity, long elem_byte_size) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total_capacity, elem_byte_size)));
    arr->len = first_dim;
    arr->capacity = total_capacity;
    arr->elem_release = NULL;
    arr->elem_size = (int16_t)elem_byte_size;
    arr->storage_mode = BLORP_VECTOR_STORAGE_INLINE;
    memset(arr->data, 0, total_capacity * elem_byte_size);
    return arr;
}

static inline void blorp_vector_fill_inline_bytes(blorp_Vector* arr, void* value) {
    if (!arr || !value) return;
    for (long i = 0; i < arr->capacity; i++) {
        memcpy((char*)arr->data + i * arr->elem_size, value, arr->elem_size);
    }
}

blorp_Vector* blorp_vector_new_fill_sized(void* value, long size, long elem_byte_size) {
    if (size < 0) size = 0;
    blorp_Vector* arr = blorp_vector_new_sized(size, elem_byte_size);
    blorp_vector_fill_inline_bytes(arr, value);
    return arr;
}

blorp_Vector* blorp_matrix_new_fill_sized(void* value, long rows, long cols, long elem_byte_size) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = blorp_tensor_new_sized(rows, total, elem_byte_size);
    blorp_vector_fill_inline_bytes(arr, value);
    return arr;
}

blorp_Vector* blorp_tensor3_new_sized(void* value, long d1, long d2, long d3, long elem_byte_size) {
    if (d1 < 0) d1 = 0;
    if (d2 < 0) d2 = 0;
    if (d3 < 0) d3 = 0;
    long total = (long)blorp_checked_mul(d1, blorp_checked_mul(d2, d3));
    blorp_Vector* arr = blorp_tensor_new_sized(d1, total, elem_byte_size);
    blorp_vector_fill_inline_bytes(arr, value);
    return arr;
}

blorp_Vector* blorp_tensor4_new_sized(void* value, long d1, long d2, long d3, long d4, long elem_byte_size) {
    if (d1 < 0) d1 = 0;
    if (d2 < 0) d2 = 0;
    if (d3 < 0) d3 = 0;
    if (d4 < 0) d4 = 0;
    long total = (long)blorp_checked_mul(blorp_checked_mul(d1, d2), blorp_checked_mul(d3, d4));
    blorp_Vector* arr = blorp_tensor_new_sized(d1, total, elem_byte_size);
    blorp_vector_fill_inline_bytes(arr, value);
    return arr;
}

blorp_Vector* blorp_tensor5_new_sized(void* value, long d1, long d2, long d3, long d4, long d5, long elem_byte_size) {
    if (d1 < 0) d1 = 0;
    if (d2 < 0) d2 = 0;
    if (d3 < 0) d3 = 0;
    if (d4 < 0) d4 = 0;
    if (d5 < 0) d5 = 0;
    long total = (long)blorp_checked_mul(blorp_checked_mul(d1, d2), blorp_checked_mul(d3, blorp_checked_mul(d4, d5)));
    blorp_Vector* arr = blorp_tensor_new_sized(d1, total, elem_byte_size);
    blorp_vector_fill_inline_bytes(arr, value);
    return arr;
}

blorp_Vector* blorp_tensor_new_f32(long first_dim, long total_capacity) {
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(total_capacity, sizeof(float))));
    arr->len = first_dim;
    arr->capacity = total_capacity;
    arr->elem_release = NULL;
    arr->elem_size = 4;
    arr->storage_mode = BLORP_VECTOR_STORAGE_F32;
    memset(arr->data, 0, total_capacity * sizeof(float));
    return arr;
}

static inline int blorp_vector_is_f64_packed(const blorp_Vector* v) {
    return v && v->storage_mode == BLORP_VECTOR_STORAGE_F64
        && v->elem_size == (int16_t)sizeof(double);
}

static inline double blorp_vector_read_f64(const blorp_Vector* v, long index) {
    if (!v || index < 0 || index >= v->capacity) return 0.0;
    if (!blorp_vector_is_f64_packed(v)) return blorp_unbox_float(v->data[index]);
    double value;
    memcpy(&value, &v->data[index], sizeof(double));
    return value;
}

static inline void blorp_vector_write_f64(blorp_Vector* v, long index, double value) {
    if (!v || index < 0 || index >= v->capacity) return;
    if (!blorp_vector_is_f64_packed(v)) {
        v->data[index] = blorp_box_float(value);
        return;
    }
    memcpy(&v->data[index], &value, sizeof(double));
}

static inline int blorp_vector_is_f32_packed(const blorp_Vector* v) {
    return v && v->storage_mode == BLORP_VECTOR_STORAGE_F32
        && v->elem_size == (int16_t)sizeof(float);
}

static inline int blorp_vector_is_i64_raw(const blorp_Vector* v) {
    return v && v->storage_mode == BLORP_VECTOR_STORAGE_I64
        && v->elem_size == (int16_t)sizeof(long);
}

static inline float blorp_vector_read_f32(const blorp_Vector* v, long index) {
    if (!v || index < 0 || index >= v->capacity) return 0.0f;
    if (blorp_vector_is_f32_packed(v)) {
        return ((float*)v->data)[index];
    }
    return blorp_unbox_float32(v->data[index]);
}

static inline void blorp_vector_write_f32(blorp_Vector* v, long index, float value) {
    if (!v || index < 0 || index >= v->capacity) return;
    if (blorp_vector_is_f32_packed(v)) {
        ((float*)v->data)[index] = value;
    } else {
        v->data[index] = blorp_box_float32(value);
    }
}

#ifdef __FLT16_MAX__
static inline _Float16 blorp_vector_read_f16(const blorp_Vector* v, long index) {
    if (!v || index < 0 || index >= v->capacity) return (_Float16)0.0;
    return blorp_unbox_float16(v->data[index]);
}

static inline void blorp_vector_write_f16(blorp_Vector* v, long index, _Float16 value) {
    if (!v || index < 0 || index >= v->capacity) return;
    v->data[index] = blorp_box_float16(value);
}
#endif

blorp_Vector* blorp_vector_new_fill_f64(double value, long size) {
    blorp_Vector* arr = blorp_vector_new_f64(size);
    for (long i = 0; i < size; i++) {
        blorp_vector_write_f64(arr, i, value);
    }
    return arr;
}

blorp_Vector* blorp_matrix_new_fill_f64(double value, long rows, long cols) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = blorp_tensor_new_f64(rows, total);
    for (long i = 0; i < total; i++) {
        blorp_vector_write_f64(arr, i, value);
    }
    return arr;
}

blorp_Vector* blorp_vector_new_fill_f32(float value, long size) {
    blorp_Vector* arr = blorp_vector_new_f32(size);
    for (long i = 0; i < size; i++) {
        ((float*)arr->data)[i] = value;
    }
    return arr;
}

blorp_Vector* blorp_matrix_new_fill_f32(float value, long rows, long cols) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = blorp_tensor_new_f32(rows, total);
    for (long i = 0; i < total; i++) {
        ((float*)arr->data)[i] = value;
    }
    return arr;
}

// Forward declaration for blorp_vector_copy (used by packed set below)
static blorp_Vector* blorp_vector_copy(blorp_Vector* src);

// ============================================================================
// Packed Enum Tensor Helpers
// ============================================================================

// Compute the number of bytes needed for n elements at sub-byte or byte granularity.
// Negative elem_size = bits per element; positive = bytes per element.
static inline long blorp_packed_byte_count(long n, int8_t es) {
    if (es > 0) return n * (long)es;
    return (n * (long)(-es) + 7) / 8;
}

// Read a packed element (sub-byte or fixed-byte) from a vector's data.
static inline long blorp_packed_get(const blorp_Vector* v, long i) {
    int8_t es = v->elem_size;
    if (es > 0) {
        uint64_t value = 0;
        memcpy(&value, (uint8_t*)v->data + i * (long)es, (size_t)es);
        return (long)value;
    }
    long bits = (long)(-es);
    long bit_pos = i * bits;
    long byte_idx = bit_pos / 8;
    long bit_offset = bit_pos % 8;
    return (((uint8_t*)v->data)[byte_idx] >> bit_offset) & ((1L << bits) - 1);
}

// Write a packed element (sub-byte or fixed-byte) into a vector's data.
static inline void blorp_packed_set(blorp_Vector* v, long i, long val) {
    int8_t es = v->elem_size;
    if (es > 0) {
        uint64_t value = (uint64_t)val;
        memcpy((uint8_t*)v->data + i * (long)es, &value, (size_t)es);
        return;
    }
    long bits = (long)(-es);
    long bit_pos = i * bits;
    long byte_idx = bit_pos / 8;
    long bit_offset = bit_pos % 8;
    long mask = (1L << bits) - 1;
    uint8_t* p = &((uint8_t*)v->data)[byte_idx];
    *p = (*p & ~(uint8_t)(mask << bit_offset)) | (uint8_t)((val & mask) << bit_offset);
}

static inline long blorp_vector_read_i64(const blorp_Vector* v, long index) {
    if (!v || index < 0 || index >= v->capacity) return 0;
    if (v->storage_mode == BLORP_VECTOR_STORAGE_I64) {
        return ((long*)v->data)[index];
    }
    if (v->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return blorp_packed_get(v, index);
    }
    return (long)(intptr_t)v->data[index];
}

static inline void blorp_vector_write_i64(blorp_Vector* v, long index, long value) {
    if (!v || index < 0 || index >= v->capacity) return;
    if (v->storage_mode == BLORP_VECTOR_STORAGE_I64) {
        ((long*)v->data)[index] = value;
        return;
    }
    if (v->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(v, index, value);
        return;
    }
    v->data[index] = (void*)(intptr_t)value;
}

// Allocate a 1D packed vector (sub-byte or 1-byte elements), zero-filled.
blorp_Vector* blorp_vector_new_packed(long size, int8_t elem_size) {
    long byte_count = blorp_packed_byte_count(size, elem_size);
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), byte_count));
    arr->len = size;
    arr->capacity = size;
    arr->elem_release = NULL;
    arr->elem_size = elem_size;
    arr->storage_mode = BLORP_VECTOR_STORAGE_PACKED;
    memset(arr->data, 0, byte_count);
    return arr;
}

// Allocate an N-D packed tensor (sub-byte or 1-byte elements), zero-filled.
blorp_Vector* blorp_tensor_new_packed(long first_dim, long total, int8_t elem_size) {
    long byte_count = blorp_packed_byte_count(total, elem_size);
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), byte_count));
    arr->len = first_dim;
    arr->capacity = total;
    arr->elem_release = NULL;
    arr->elem_size = elem_size;
    arr->storage_mode = BLORP_VECTOR_STORAGE_PACKED;
    memset(arr->data, 0, byte_count);
    return arr;
}

blorp_Vector* blorp_vector_new_fill_packed(long value, long size, int8_t elem_size) {
    blorp_Vector* arr = blorp_vector_new_packed(size, elem_size);
    for (long i = 0; i < size; i++) {
        blorp_packed_set(arr, i, value);
    }
    return arr;
}

blorp_Vector* blorp_matrix_new_fill_packed(long value, long rows, long cols, int8_t elem_size) {
    if (rows < 0) rows = 0;
    if (cols < 0) cols = 0;
    long total = (long)blorp_checked_mul(rows, cols);
    blorp_Vector* arr = blorp_tensor_new_packed(rows, total, elem_size);
    for (long i = 0; i < total; i++) {
        blorp_packed_set(arr, i, value);
    }
    return arr;
}

// COW-safe set for packed vectors. Returns the (possibly copied) vector.
blorp_Vector* blorp_vector_set_inplace_packed(blorp_Vector* arr, long index, long value) {
    if (!arr || index < 0 || index >= arr->capacity) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_packed_set(result, index, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

// Convert a packed enum vector to string using a per-variant callback.
blorp_String* blorp_vector_to_string_packed_enum(blorp_Vector* v, blorp_String* (*to_str)(long)) {
    if (!v || v->capacity == 0) {
        return blorp_string_literal("{}");
    }
    // Build string: {Variant1, Variant2, ...}
    // Start with "{"
    blorp_String* result = blorp_string_literal("{");
    for (long i = 0; i < v->capacity; i++) {
        if (i > 0) {
            blorp_String* sep = blorp_string_literal(", ");
            result = blorp_string_concat_consume(result, sep);
        }
        long val = (v->storage_mode == BLORP_VECTOR_STORAGE_POINTER
                    && v->elem_size == (int16_t)sizeof(void*))
            ? (long)v->data[i]
            : blorp_packed_get(v, i);
        blorp_String* elem_str = to_str(val);
        result = blorp_string_concat_consume(result, elem_str);
    }
    blorp_String* close = blorp_string_literal("}");
    result = blorp_string_concat_consume(result, close);
    return result;
}

blorp_String* blorp_vector_to_string_bool(blorp_Vector* v) {
    return blorp_vector_to_string_packed_enum(v, blorp_bool_to_string_long);
}

// (removed blorp_vector_len — now IR intrinsic)

// Safe: returns NULL on bounds error (consistent with uninitialized element)
void* blorp_vector_get(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return NULL;
    }
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[index];
    }
    return arr->data[index];
}

// Safe: silently ignores out-of-bounds writes (no-op)
// WARNING: This mutates in-place without COW check - only use when you know the vector is unique
void blorp_vector_set(blorp_Vector* arr, long index, void* value) {
    if (!arr || index < 0 || index >= arr->len) {
        return;  // Silently ignore invalid set
    }
    if (blorp_vector_is_i64_raw(arr)) {
        ((long*)arr->data)[index] = (long)(intptr_t)value;
        return;
    }
    arr->data[index] = value;
}

// Checked subscript access — safe bounds-checked element read.
// Returns a borrowed raw void* from data[index]. The compiler's ownership
// contract for checked_get is ReturnAliasOfArg(0), so any longer-lived local
// binding must retain explicitly in generated code.
void* blorp_checked_get(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) return 0;
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[index];
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return (void*)(intptr_t)blorp_packed_get(arr, index);
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + index * arr->elem_size,
               arr->elem_size);
        return boxed;
    }
    return arr->data[index];
}

double blorp_checked_get_f64(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) return 0.0;
    return blorp_vector_read_f64(arr, index);
}

float blorp_checked_get_f32(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) return 0.0f;
    return blorp_vector_read_f32(arr, index);
}

// Forward decl — implementation lives below blorp_vector_copy.
blorp_Vector* blorp_vector_set_inplace(blorp_Vector* arr, long index, void* value);

// Checked subscript write — safe bounds-checked element write with COW.
// Returns the (possibly newly-allocated) vector. Handles inline-struct
// storage, element retain/release for RC payloads, and COW on shared input.
blorp_Vector* blorp_checked_set(blorp_Vector* arr, long index, void* value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    return blorp_vector_set_inplace(arr, index, value);
}

// Bounds-checked 1D slice [start, end_idx). Clamps start/end_idx to [0, len].
// Returns a new independently-owned blorp_Vector with the selected elements.
// Retains element references for RC types. Preserves elem_size/storage_mode
// so packed tensors (sub-byte elements) are sliced at the byte level.
blorp_Vector* blorp_checked_slice(blorp_Vector* arr, long start, long end_idx) {
    long in_len = arr ? arr->len : 0;
    long s = start < 0 ? 0 : (start > in_len ? in_len : start);
    long e = end_idx < 0 ? 0 : (end_idx > in_len ? in_len : end_idx);
    long out_len = e > s ? e - s : 0;
    if (!arr || out_len == 0) {
        blorp_Vector* empty =
            arr && arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED
                ? blorp_vector_new_packed(0, (int8_t)arr->elem_size)
                : blorp_vector_new_noinit(0);
        if (arr) {
            empty->elem_release = arr->elem_release;
            empty->elem_size = arr->elem_size;
            empty->storage_mode = arr->storage_mode;
            if (arr->elem_release) BLORP_SET_DESTRUCTOR(empty, blorp_vector_destroy);
        }
        empty->len = 0;
        return empty;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_Vector* out = blorp_vector_new_packed(out_len, (int8_t)arr->elem_size);
        for (long i = 0; i < out_len; i++) {
            blorp_packed_set(out, i, blorp_packed_get(arr, s + i));
        }
        return out;
    }
    long byte_size = blorp_packed_byte_count(out_len, arr->elem_size);
    blorp_Vector* out = (blorp_Vector*)blorp_alloc(
        blorp_checked_add(sizeof(blorp_Vector), byte_size));
    out->len = out_len;
    out->capacity = out_len;
    out->elem_release = arr->elem_release;
    out->elem_size = arr->elem_size;
    out->storage_mode = arr->storage_mode;
    if (out->elem_release) BLORP_SET_DESTRUCTOR(out, blorp_vector_destroy);
    // Packed byte copy handles both pointer-sized and sub-byte elements.
    long src_offset_bytes = blorp_packed_byte_count(s, arr->elem_size);
    memcpy(out->data, (char*)arr->data + src_offset_bytes, byte_size);
    if (out->elem_release) {
        for (long i = 0; i < out_len; i++) {
            if (out->data[i]) blorp_retain(out->data[i]);
        }
    }
    return out;
}

// N-D checked get — flat index into capacity-sized data array
void* blorp_matrix_checked_get(blorp_Vector* arr, long row, long col) {
    if (!arr || row < 0 || col < 0) return 0;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return 0;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return 0;
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[idx];
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return (void*)(intptr_t)blorp_packed_get(arr, idx);
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + idx * arr->elem_size,
               arr->elem_size);
        return boxed;
    }
    return arr->data[idx];
}

double blorp_matrix_checked_get_f64(blorp_Vector* arr, long row, long col) {
    if (!arr || row < 0 || col < 0) return 0.0;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return 0.0;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return 0.0;
    return blorp_vector_read_f64(arr, idx);
}

float blorp_matrix_checked_get_f32(blorp_Vector* arr, long row, long col) {
    if (!arr || row < 0 || col < 0) return 0.0f;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return 0.0f;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return 0.0f;
    return blorp_vector_read_f32(arr, idx);
}

// Returns the (possibly newly-allocated) matrix. Does COW + retain/release
// for RC payloads. Uses row-major flat indexing; cols derived from
// capacity/rows (len==rows for 2D).
blorp_Vector* blorp_matrix_checked_set(blorp_Vector* arr, long row, long col, void* value) {
    if (!arr || row < 0 || col < 0) return arr;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return arr;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (blorp_vector_is_i64_raw(result)) {
        ((long*)result->data)[idx] = (long)(intptr_t)value;
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(result, idx, (long)(intptr_t)value);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->storage_mode == BLORP_VECTOR_STORAGE_INLINE && value) {
        memcpy((char*)result->data + idx * result->elem_size,
               (char*)value + sizeof(blorp_Object),
               result->elem_size);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->elem_release && result->data[idx]) {
        result->elem_release(result->data[idx]);
    }
    result->data[idx] = value;
    if (result->elem_release && value) blorp_retain(value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

blorp_Vector* blorp_matrix_checked_set_f64(blorp_Vector* arr, long row, long col, double value) {
    if (!arr || row < 0 || col < 0) return arr;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return arr;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_f64(result, idx, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

blorp_Vector* blorp_matrix_checked_set_f32(blorp_Vector* arr, long row, long col, float value) {
    if (!arr || row < 0 || col < 0) return arr;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return arr;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_f32(result, idx, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

blorp_Vector* blorp_matrix_checked_set_i64(blorp_Vector* arr, long row, long col, long value) {
    if (!arr || row < 0 || col < 0) return arr;
    long cols = arr->len > 0 ? arr->capacity / arr->len : 0;
    if (row >= arr->len || col >= cols) return arr;
    long idx = row * cols + col;
    if (idx < 0 || idx >= arr->capacity) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_i64(result, idx, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

// Helper to copy vector (for COW semantics)
static blorp_Vector* blorp_vector_copy(blorp_Vector* src) {
    if (!src) return blorp_vector_new(0);
    long byte_size = blorp_packed_byte_count(src->capacity, src->elem_size);
    blorp_Vector* arr = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), byte_size));
    arr->len = src->len;
    arr->capacity = src->capacity;
    arr->elem_release = src->elem_release;
    arr->elem_size = src->elem_size;
    arr->storage_mode = src->storage_mode;
    if (arr->elem_release) {
        BLORP_SET_DESTRUCTOR(arr, blorp_vector_destroy);
    }
    memcpy(arr->data, src->data, byte_size);
    if (arr->elem_release) {
        // Use capacity for 2D matrices
        for (long i = 0; i < arr->capacity; i++) {
            if (arr->data[i]) blorp_retain(arr->data[i]);
        }
    }
    return arr;
}

// FFI copy: create independent deep copy of a vector/tensor (refcount = 1, elements retained)
blorp_Vector* blorp_vector_copy_ffi(blorp_Vector* src) {
    return blorp_vector_copy(src);
}

// Allocate a new vector with the same shape (len/capacity) as src.
// For 1D: len == capacity (no change). For 2D: preserves row count.
// Note: Binary ops require same-shape operands (enforced by type system).
// These helpers preserve the shape of the first operand.
static inline blorp_Vector* blorp_vector_new_like(const blorp_Vector* src) {
    if (blorp_vector_is_f64_packed(src)) {
        blorp_Vector* v = blorp_vector_new_f64(src->capacity);
        v->len = src->len;
        return v;
    }
    if (blorp_vector_is_i64_raw(src)) {
        blorp_Vector* v = blorp_vector_new_i64(src->capacity);
        v->len = src->len;
        return v;
    }
    blorp_Vector* v = blorp_vector_new_noinit(src->capacity);
    v->len = src->len;
    return v;
}

static inline blorp_Vector* blorp_vector_new_f64_like_noinit(const blorp_Vector* src) {
    blorp_Vector* v = blorp_vector_new_f64_noinit(src ? src->capacity : 0);
    if (src) v->len = src->len;
    return v;
}

static inline blorp_Vector* blorp_vector_new_i64_like_noinit(const blorp_Vector* src) {
    blorp_Vector* v = blorp_vector_new_i64_noinit(src ? src->capacity : 0);
    if (src) v->len = src->len;
    return v;
}

static inline void blorp_vector_zero_i64_tail(blorp_Vector* v, long filled) {
    if (!v || filled >= v->capacity) return;
    if (filled < 0) filled = 0;
    memset(((long*)v->data) + filled, 0, (size_t)(v->capacity - filled) * sizeof(long));
}

static inline blorp_Vector* blorp_vector_new_f32_like(const blorp_Vector* src) {
    blorp_Vector* v = blorp_vector_new_f32(src->capacity);
    v->len = src->len;
    return v;
}

static inline blorp_Vector* blorp_vector_new_f32_like_noinit(const blorp_Vector* src) {
    blorp_Vector* v = blorp_vector_new_f32_noinit(src ? src->capacity : 0);
    if (src) v->len = src->len;
    return v;
}

// Float16 uses void*-boxed storage (8 bytes per element), same as new_like.
static inline blorp_Vector* blorp_vector_new_f16_like(const blorp_Vector* src) {
    blorp_Vector* v = blorp_vector_new_noinit(src->capacity);
    v->len = src->len;
    return v;
}

// COW ensure unique: if shared, copy and release old. Returns unique-owned vector.
// Caller must update their variable: v = blorp_vector_cow_unique(v);
blorp_Vector* blorp_vector_cow_unique(blorp_Vector* arr) {
    if (!arr) return arr;
    if (blorp_is_unique(arr)) return arr;
    blorp_Vector* copy = blorp_vector_copy(arr);
    blorp_release((blorp_Object*)arr);
    return copy;
}

// Parse a JSON float array directly from a raw JSON string.
// Searches for "field_name": [...] and extracts floats into a Vector.
// Bypasses the recursive parser combinator for large arrays (>1000 elements).
blorp_Vector* blorp_parse_json_float_array(const char* json, const char* field_name) {
    if (!json || !field_name) return blorp_vector_new(0);
    char needle[256];
    int nlen = snprintf(needle, sizeof(needle), "\"%s\"", field_name);
    if (nlen < 0 || nlen >= (int)sizeof(needle)) return blorp_vector_new(0);
    char* pos = strstr(json, needle);
    if (!pos) return blorp_vector_new(0);
    pos += nlen;
    while (*pos && (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r' || *pos == ':')) pos++;
    if (*pos != '[') return blorp_vector_new(0);
    pos++;
    // Count elements
    long count = 0;
    { char* scan = pos; int depth = 0;
      while (*scan && !(*scan == ']' && depth == 0)) {
          if (*scan == '[') depth++;
          else if (*scan == ']') depth--;
          else if (*scan == ',' && depth == 0) count++;
          scan++;
      }
      if (*scan == ']' && scan > pos) count++;
    }
    if (count == 0) return blorp_vector_new_f64(0);
    blorp_Vector* result = blorp_vector_new_f64(count);
    long idx = 0;
    char* end = pos;
    while (idx < count && *end) {
        while (*end && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) end++;
        if (*end == ']') break;
        double val = strtod(end, &end);
        blorp_vector_write_f64(result, idx, val);
        idx++;
        while (*end && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r' || *end == ',')) end++;
    }
    return result;
}

// Strip a large JSON array field, replacing its contents with [].
// Used to pre-process NAM files so the blorp JSON parser doesn't overflow.
// Returns a malloc'd C string (caller frees via blorp_string_create wrapping).
char* blorp_json_strip_array(const char* json, const char* field_name) {
    if (!json || !field_name) return strdup("");
    char needle[256];
    int nlen = snprintf(needle, sizeof(needle), "\"%s\"", field_name);
    if (nlen < 0 || nlen >= (int)sizeof(needle)) return strdup(json);
    char* pos = strstr(json, needle);
    if (!pos) return strdup(json);
    pos += nlen;
    while (*pos && (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r' || *pos == ':')) pos++;
    if (*pos != '[') return strdup(json);
    const char* array_start = pos;
    // Find matching ]
    int depth = 1;
    pos++;
    while (*pos && depth > 0) {
        if (*pos == '[') depth++;
        else if (*pos == ']') depth--;
        pos++;
    }
    const char* array_end = pos;
    long json_len = (long)strlen(json);
    long before_len = array_start - json;
    long after_len = json_len - (array_end - json);
    // Build: before + "[]" + after
    long new_len = before_len + 2 + after_len;
    char* result = (char*)malloc(new_len + 1);
    memcpy(result, json, before_len);
    result[before_len] = '[';
    result[before_len + 1] = ']';
    memcpy(result + before_len + 2, array_end, after_len);
    result[new_len] = '\0';
    return result;
}

// Forward declaration of blorp_Option (defined in List section)
// blorp_Option* blorp_option_some(void* value);
// blorp_Option* blorp_option_none(void);

// Set element at index, COW inplace (returns Vector, no Option wrapper).
// On out-of-bounds: returns arr unchanged. On success: consumes arr by
// modifying in-place when unique, otherwise COW-copying and releasing arr.
blorp_Vector* blorp_vector_set_inplace(blorp_Vector* arr, long index, void* value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (blorp_vector_is_i64_raw(result)) {
        ((long*)result->data)[index] = (long)(intptr_t)value;
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    // Inline struct storage: value is a boxed struct pointer borrowed from the caller.
    if (result->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(result, index, (long)(intptr_t)value);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->storage_mode == BLORP_VECTOR_STORAGE_INLINE && value) {
        memcpy((char*)result->data + index * result->elem_size,
               (char*)value + sizeof(blorp_Object),
               result->elem_size);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->elem_release && result->data[index]) {
        result->elem_release(result->data[index]);
    }
    result->data[index] = value;
    if (result->elem_release && value) {
        blorp_retain(value);
    }
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

blorp_Vector* blorp_vector_set_inplace_i64(blorp_Vector* arr, long index, long value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_i64(result, index, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

// Float32 packed variant of set_inplace.
blorp_Vector* blorp_vector_set_inplace_f32(blorp_Vector* arr, long index, float value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_f32(result, index, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

// Float64 packed variant of set_inplace (stores double via memcpy in void* slots).
blorp_Vector* blorp_vector_set_inplace_f64(blorp_Vector* arr, long index, double value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_f64(result, index, value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

// Float16 packed variant of set_inplace.
blorp_Vector* blorp_vector_set_inplace_f16(blorp_Vector* arr, long index, _Float16 value) {
    if (!arr || index < 0 || index >= arr->len) return arr;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    result->data[index] = blorp_box_float16(value);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

static blorp_Vector* blorp_vector_set_cow_result(blorp_Vector* arr, long index, void* value) {
    if (!arr || index < 0 || index >= arr->len) {
        // Do NOT release arr on OOB — caller may still reference it
        // (e.g., unwrap_or(set_index(v, i, val), v) needs v alive for fallback)
        return NULL;
    }
    // COW: copy if shared
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (result != arr) {
        blorp_release(arr);
    }
    if (blorp_vector_is_i64_raw(result)) {
        ((long*)result->data)[index] = (long)(intptr_t)value;
        return result;
    }
    // Inline struct storage: unbox the caller-owned temporary and copy bytes.
    if (result->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(result, index, (long)(intptr_t)value);
    } else if (result->storage_mode == BLORP_VECTOR_STORAGE_INLINE && value) {
        memcpy((char*)result->data + index * result->elem_size,
               (char*)value + sizeof(blorp_Object),
               result->elem_size);
    } else {
        if (result->elem_release && result->data[index]) {
            result->elem_release(result->data[index]);
        }
        result->data[index] = value;
        if (result->elem_release && value) {
            blorp_retain(value);
        }
    }
    return result;
}

blorp_Vector* blorp_vector_set_cow_nullable(blorp_Vector* arr, long index, void* value) {
    return blorp_vector_set_cow_result(arr, index, value);
}

// Set element at index with COW semantics (returns Option[Vector])
blorp_Option* blorp_vector_set_cow(blorp_Vector* arr, long index, void* value) {
    blorp_Vector* result = blorp_vector_set_cow_result(arr, index, value);
    if (!result) return blorp_option_none();
    blorp_Option* opt = blorp_option_some((void*)result);
    opt->release_mask = 1UL;
    return opt;
}

static blorp_Vector* blorp_vector_set_cow_i64_result(blorp_Vector* arr, long index, long value) {
    if (!arr || index < 0 || index >= arr->len) {
        return NULL;
    }
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (result != arr) blorp_release((blorp_Object*)arr);
    blorp_vector_write_i64(result, index, value);
    return result;
}

blorp_Vector* blorp_vector_set_cow_nullable_i64(blorp_Vector* arr, long index, long value) {
    return blorp_vector_set_cow_i64_result(arr, index, value);
}

blorp_Option* blorp_vector_set_cow_i64(blorp_Vector* arr, long index, long value) {
    blorp_Vector* result = blorp_vector_set_cow_i64_result(arr, index, value);
    if (!result) return blorp_option_none();
    blorp_Option* opt = blorp_option_some((void*)result);
    opt->release_mask = 1UL;
    return opt;
}

// Get element at index with bounds checking (returns Option)
blorp_Option* blorp_vector_get_opt(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_option_none();
    }
    if (blorp_vector_is_i64_raw(arr)) {
        return blorp_option_some((void*)(intptr_t)((long*)arr->data)[index]);
    }
    // Inline struct storage means data is packed bytes, not pointers.
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + index * arr->elem_size,
               arr->elem_size);
        blorp_Option* opt = blorp_option_some(boxed);
        opt->release_mask = 1UL;
        return opt;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return blorp_option_some((void*)(intptr_t)blorp_packed_get(arr, index));
    }
    void* value = arr->data[index];
    if (arr->elem_release && value) {
        blorp_retain(value);
    }
    blorp_Option* opt = blorp_option_some(value);
    if (arr->elem_release && value) {
        opt->release_mask = 1UL;
    }
    return opt;
}

void* blorp_vector_get_nullable(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return NULL;
    }
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[index];
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + index * arr->elem_size,
               arr->elem_size);
        return boxed;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return (void*)(intptr_t)blorp_packed_get(arr, index);
    }
    void* value = arr->data[index];
    if (arr->elem_release && value) {
        blorp_retain(value);
    }
    return value;
}

blorp_StackOption_Int blorp_vector_get_opt_int(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_int_none();
    }
    return blorp_stack_option_int_some(blorp_vector_read_i64(arr, index));
}

#define BLORP_DEFINE_VECTOR_GET_OPT_SIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_vector_get_opt_##SUFFIX(blorp_Vector* arr, long index) { \
    if (!arr || index < 0 || index >= arr->len) { \
        return blorp_stack_option_##SUFFIX##_none(); \
    } \
    return blorp_stack_option_##SUFFIX##_some((CTYPE)blorp_vector_read_i64(arr, index)); \
}

#define BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_vector_get_opt_##SUFFIX(blorp_Vector* arr, long index) { \
    if (!arr || index < 0 || index >= arr->len) { \
        return blorp_stack_option_##SUFFIX##_none(); \
    } \
    return blorp_stack_option_##SUFFIX##_some((CTYPE)(uint64_t)blorp_vector_read_i64(arr, index)); \
}

BLORP_DEFINE_VECTOR_GET_OPT_SIGNED(int8, Int8, int8_t)
BLORP_DEFINE_VECTOR_GET_OPT_SIGNED(int16, Int16, int16_t)
BLORP_DEFINE_VECTOR_GET_OPT_SIGNED(int32, Int32, int32_t)
BLORP_DEFINE_VECTOR_GET_OPT_SIGNED(int64, Int64, long)
BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED(uint8, UInt8, uint8_t)
BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED(uint16, UInt16, uint16_t)
BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED(uint32, UInt32, uint32_t)
BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED(uint64, UInt64, uint64_t)

#undef BLORP_DEFINE_VECTOR_GET_OPT_SIGNED
#undef BLORP_DEFINE_VECTOR_GET_OPT_UNSIGNED

blorp_StackOption_Float blorp_vector_get_opt_float(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_float_none();
    }
    return blorp_stack_option_float_some(blorp_vector_read_f64(arr, index));
}

blorp_StackOption_Bool blorp_vector_get_opt_bool(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_bool_none();
    }
    return blorp_stack_option_bool_some(blorp_vector_read_i64(arr, index));
}

blorp_StackOption_Char blorp_vector_get_opt_char(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_char_none();
    }
    return blorp_stack_option_char_some((int32_t)blorp_vector_read_i64(arr, index));
}


// get_or: returns element directly (no Option), or default if out of bounds
void* blorp_vector_get_or(blorp_Vector* arr, long index, void* default_val) {
    if (!arr || index < 0 || index >= arr->len) return default_val;
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[index];
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        // Inline struct: allocate box and copy from inline data
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + index * arr->elem_size, arr->elem_size);
        return boxed;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return (void*)(intptr_t)blorp_packed_get(arr, index);
    }
    return arr->data[index];
}

// Float32 packed get: returns stack Option[Float32]
blorp_StackOption_Float32 blorp_vector_get_opt_f32(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_float32_none();
    }
    float val = blorp_vector_read_f32(arr, index);
    return blorp_stack_option_float32_some(val);
}

#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_vector_get_opt_f16(blorp_Vector* arr, long index) {
    if (!arr || index < 0 || index >= arr->len) {
        return blorp_stack_option_float16_none();
    }
    return blorp_stack_option_float16_some(blorp_vector_read_f16(arr, index));
}
#endif

// 2D matrix get: bounds-check row and col, return Option[T]
// Matrix is stored flat row-major: arr->len = rows, arr->capacity = rows * cols
blorp_Option* blorp_matrix_get_opt(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_option_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_option_none();
    }
    long offset = row * cols + col;
    if (blorp_vector_is_i64_raw(arr)) {
        return blorp_option_some((void*)(intptr_t)((long*)arr->data)[offset]);
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + offset * arr->elem_size,
               arr->elem_size);
        blorp_Option* opt = blorp_option_some(boxed);
        opt->release_mask = 1UL;
        return opt;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return blorp_option_some((void*)(intptr_t)blorp_packed_get(arr, offset));
    }
    void* value = arr->data[offset];
    if (arr->elem_release && value) {
        blorp_retain(value);
    }
    blorp_Option* opt = blorp_option_some(value);
    if (arr->elem_release && value) {
        opt->release_mask = 1UL;
    }
    return opt;
}

void* blorp_matrix_get_nullable(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return NULL;
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return NULL;
    }
    long offset = row * cols + col;
    if (blorp_vector_is_i64_raw(arr)) {
        return (void*)(intptr_t)((long*)arr->data)[offset];
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* boxed = blorp_alloc(sizeof(blorp_Object) + arr->elem_size);
        memcpy((char*)boxed + sizeof(blorp_Object),
               (char*)arr->data + offset * arr->elem_size,
               arr->elem_size);
        return boxed;
    }
    if (arr->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        return (void*)(intptr_t)blorp_packed_get(arr, offset);
    }
    void* value = arr->data[offset];
    if (arr->elem_release && value) {
        blorp_retain(value);
    }
    return value;
}

blorp_StackOption_Int blorp_matrix_get_opt_int(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_int_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_int_none();
    }
    return blorp_stack_option_int_some(
        blorp_vector_read_i64(arr, row * cols + col));
}

#define BLORP_DEFINE_MATRIX_GET_OPT_SIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_matrix_get_opt_##SUFFIX(blorp_Vector* arr, long row, long col) { \
    if (!arr || arr->len <= 0) return blorp_stack_option_##SUFFIX##_none(); \
    long cols = arr->capacity / arr->len; \
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) { \
        return blorp_stack_option_##SUFFIX##_none(); \
    } \
    return blorp_stack_option_##SUFFIX##_some((CTYPE)blorp_vector_read_i64(arr, row * cols + col)); \
}

#define BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_matrix_get_opt_##SUFFIX(blorp_Vector* arr, long row, long col) { \
    if (!arr || arr->len <= 0) return blorp_stack_option_##SUFFIX##_none(); \
    long cols = arr->capacity / arr->len; \
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) { \
        return blorp_stack_option_##SUFFIX##_none(); \
    } \
    return blorp_stack_option_##SUFFIX##_some((CTYPE)(uint64_t)blorp_vector_read_i64(arr, row * cols + col)); \
}

BLORP_DEFINE_MATRIX_GET_OPT_SIGNED(int8, Int8, int8_t)
BLORP_DEFINE_MATRIX_GET_OPT_SIGNED(int16, Int16, int16_t)
BLORP_DEFINE_MATRIX_GET_OPT_SIGNED(int32, Int32, int32_t)
BLORP_DEFINE_MATRIX_GET_OPT_SIGNED(int64, Int64, long)
BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED(uint8, UInt8, uint8_t)
BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED(uint16, UInt16, uint16_t)
BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED(uint32, UInt32, uint32_t)
BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED(uint64, UInt64, uint64_t)

#undef BLORP_DEFINE_MATRIX_GET_OPT_SIGNED
#undef BLORP_DEFINE_MATRIX_GET_OPT_UNSIGNED

blorp_StackOption_Float blorp_matrix_get_opt_float(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_float_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_float_none();
    }
    return blorp_stack_option_float_some(blorp_vector_read_f64(arr, row * cols + col));
}

blorp_StackOption_Bool blorp_matrix_get_opt_bool(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_bool_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_bool_none();
    }
    return blorp_stack_option_bool_some(
        blorp_vector_read_i64(arr, row * cols + col));
}

blorp_StackOption_Char blorp_matrix_get_opt_char(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_char_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_char_none();
    }
    return blorp_stack_option_char_some(
        (int32_t)blorp_vector_read_i64(arr, row * cols + col));
}

blorp_StackOption_Float32 blorp_matrix_get_opt_f32(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_float32_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_float32_none();
    }
    return blorp_stack_option_float32_some(blorp_vector_read_f32(arr, row * cols + col));
}

#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_matrix_get_opt_f16(blorp_Vector* arr, long row, long col) {
    if (!arr || arr->len <= 0) return blorp_stack_option_float16_none();
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return blorp_stack_option_float16_none();
    }
    return blorp_stack_option_float16_some(blorp_vector_read_f16(arr, row * cols + col));
}
#endif

static blorp_Vector* blorp_matrix_set_result(blorp_Vector* arr, long row, long col, void* val) {
    if (!arr || arr->len <= 0) return NULL;
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return NULL;
    }
    long offset = row * cols + col;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (blorp_vector_is_i64_raw(result)) {
        ((long*)result->data)[offset] = (long)(intptr_t)val;
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(result, offset, (long)(intptr_t)val);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->storage_mode == BLORP_VECTOR_STORAGE_INLINE && val) {
        memcpy((char*)result->data + offset * result->elem_size,
               (char*)val + sizeof(blorp_Object),
               result->elem_size);
        blorp_release_cow_input_if_copied(arr, result);
        return result;
    }
    if (result->elem_release && result->data[offset]) {
        result->elem_release(result->data[offset]);
    }
    result->data[offset] = val;
    if (result->elem_release && val) blorp_retain(val);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

static blorp_Vector* blorp_matrix_set_i64_result(blorp_Vector* arr, long row, long col, long val) {
    if (!arr || arr->len <= 0) return NULL;
    long cols = arr->capacity / arr->len;
    if (row < 0 || row >= arr->len || col < 0 || col >= cols) {
        return NULL;
    }
    long offset = row * cols + col;
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    blorp_vector_write_i64(result, offset, val);
    blorp_release_cow_input_if_copied(arr, result);
    return result;
}

blorp_Vector* blorp_matrix_set_opt_nullable(blorp_Vector* arr, long row, long col, void* val) {
    return blorp_matrix_set_result(arr, row, col, val);
}

blorp_Vector* blorp_matrix_set_opt_nullable_i64(blorp_Vector* arr, long row, long col, long val) {
    return blorp_matrix_set_i64_result(arr, row, col, val);
}

// 2D matrix set: bounds-check row and col, COW + set, return Option[Matrix]
blorp_Option* blorp_matrix_set_opt(blorp_Vector* arr, long row, long col, void* val) {
    blorp_Vector* result = blorp_matrix_set_result(arr, row, col, val);
    if (!result) return blorp_option_none();
    blorp_Option* opt = blorp_option_some(result);
    opt->release_mask = 1UL;
    return opt;
}

blorp_Option* blorp_matrix_set_opt_i64(blorp_Vector* arr, long row, long col, long val) {
    blorp_Vector* result = blorp_matrix_set_i64_result(arr, row, col, val);
    if (!result) return blorp_option_none();
    blorp_Option* opt = blorp_option_some(result);
    opt->release_mask = 1UL;
    return opt;
}


// Element-wise array operation
// op: 0=add, 1=sub, 2=mul, 3=div
// elem_type: 0=int64, 1=float64
blorp_Vector* blorp_vector_op(int op, int elem_type, const blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long total = a->capacity < b->capacity ? a->capacity : b->capacity;
    blorp_Vector* result = blorp_vector_new_like(a);

    if (elem_type == 0) {
        // Int64 elements: raw i64 when available, legacy immediate slots otherwise.
        for (long i = 0; i < total; i++) {
            long va = blorp_vector_read_i64(a, i);
            long vb = blorp_vector_read_i64(b, i);
            long vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0) ? 0 : va / vb; break;  // Safe division
                default: vr = 0;
            }
            blorp_vector_write_i64(result, i, vr);
        }
    } else if (elem_type == 1) {
        // Float64 elements.
        for (long i = 0; i < total; i++) {
            double va = blorp_vector_read_f64(a, i);
            double vb = blorp_vector_read_f64(b, i);
            double vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0.0) ? 0.0 : va / vb; break;  // Safe division
                default: vr = 0.0;
            }
            blorp_vector_write_f64(result, i, vr);
        }
    } else if (elem_type == 2) {
        // Float32 elements
        blorp_Vector* f32_result = blorp_vector_new_f32_like(a);
        for (long i = 0; i < total; i++) {
            float va = blorp_vector_read_f32(a, i);
            float vb = blorp_vector_read_f32(b, i);
            float vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0.0f) ? 0.0f : va / vb; break;
                default: vr = 0.0f;
            }
            blorp_vector_write_f32(f32_result, i, vr);
        }
        return f32_result;
    } else if (elem_type == 3) {
        // Float16 elements
        for (long i = 0; i < total; i++) {
            float va = (float)blorp_unbox_float16(a->data[i]);
            float vb = (float)blorp_unbox_float16(b->data[i]);
            float vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0.0f) ? 0.0f : va / vb; break;
                default: vr = 0.0f;
            }
            result->data[i] = blorp_box_float16((_Float16)vr);
        }
    }
    return result;
}

#define BLORP_DEFINE_VECTOR_I64_BINARY(NAME, EXPR) \
blorp_Vector* NAME(const blorp_Vector* a, const blorp_Vector* b) { \
    if (!a || !b) return NULL; \
    long total = a->capacity < b->capacity ? a->capacity : b->capacity; \
    blorp_Vector* result = blorp_vector_new_i64_like_noinit(a); \
    if (blorp_vector_is_i64_raw(a) && blorp_vector_is_i64_raw(b)) { \
        const long* ad = (const long*)a->data; \
        const long* bd = (const long*)b->data; \
        long* rd = (long*)result->data; \
        for (long i = 0; i < total; i++) { \
            long va = ad[i]; \
            long vb = bd[i]; \
            rd[i] = (EXPR); \
        } \
    } else { \
        for (long i = 0; i < total; i++) { \
            long va = blorp_vector_read_i64(a, i); \
            long vb = blorp_vector_read_i64(b, i); \
            blorp_vector_write_i64(result, i, (EXPR)); \
        } \
    } \
    blorp_vector_zero_i64_tail(result, total); \
    return result; \
}

BLORP_DEFINE_VECTOR_I64_BINARY(blorp_vector_add_i64, va + vb)
BLORP_DEFINE_VECTOR_I64_BINARY(blorp_vector_sub_i64, va - vb)
BLORP_DEFINE_VECTOR_I64_BINARY(blorp_vector_mul_i64, va * vb)
BLORP_DEFINE_VECTOR_I64_BINARY(blorp_vector_div_i64, vb == 0 ? 0 : va / vb)
BLORP_DEFINE_VECTOR_I64_BINARY(blorp_vector_mod_i64, vb == 0 ? 0 : va % vb)

#undef BLORP_DEFINE_VECTOR_I64_BINARY

// COW element-wise: result[i] = a[i] OP b[i] (in-place when a is unique)
blorp_Vector* blorp_vector_op_cow(int op, int elem_type, blorp_Vector* a, const blorp_Vector* b) {
    if (!a || !b) return NULL;
    long total = a->capacity < b->capacity ? a->capacity : b->capacity;
    int is_unique_a = blorp_is_unique(a);
    blorp_Vector* result;
    if (is_unique_a) {
        result = a;
    } else {
        result = blorp_vector_new_like(a);
    }

    if (elem_type == 0) {
        for (long i = 0; i < total; i++) {
            long va = blorp_vector_read_i64(a, i);
            long vb = blorp_vector_read_i64(b, i);
            long vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0) ? 0 : va / vb; break;
                default: vr = 0;
            }
            blorp_vector_write_i64(result, i, vr);
        }
    } else if (elem_type == 1) {
        for (long i = 0; i < total; i++) {
            double va = blorp_vector_read_f64(a, i);
            double vb = blorp_vector_read_f64(b, i);
            double vr;
            switch (op) {
                case 0: vr = va + vb; break;
                case 1: vr = va - vb; break;
                case 2: vr = va * vb; break;
                case 3: vr = (vb == 0.0) ? 0.0 : va / vb; break;
                default: vr = 0.0;
            }
            blorp_vector_write_f64(result, i, vr);
        }
    }
    blorp_release_cow_input_if_copied(a, result);
    return result;
}

// ============================================================================
// Numeric Vector Builtins (tight loops, autovectorizable with -O2)
// ============================================================================

// Sum all Int elements in a vector (SIMD-accelerated)
long blorp_vector_max_int(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0;
    long max_val = blorp_vector_read_i64(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        long val = blorp_vector_read_i64(v, i);
        if (val > max_val) max_val = val;
    }
    return max_val;
}

// Min of all Int elements (returns 0 if empty — no-panic design)
long blorp_vector_min_int(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0;
    long min_val = blorp_vector_read_i64(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        long val = blorp_vector_read_i64(v, i);
        if (val < min_val) min_val = val;
    }
    return min_val;
}

double blorp_vector_max_float(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0.0;
    double max_val = blorp_vector_read_f64(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        double val = blorp_vector_read_f64(v, i);
        if (val > max_val) max_val = val;
    }
    return max_val;
}

double blorp_vector_min_float(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0.0;
    double min_val = blorp_vector_read_f64(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        double val = blorp_vector_read_f64(v, i);
        if (val < min_val) min_val = val;
    }
    return min_val;
}

float blorp_vector_max_float32(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0.0f;
    float max_val = blorp_vector_read_f32(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        float val = blorp_vector_read_f32(v, i);
        if (val > max_val) max_val = val;
    }
    return max_val;
}

float blorp_vector_min_float32(blorp_Vector* v) {
    if (!v || v->capacity == 0) return 0.0f;
    float min_val = blorp_vector_read_f32(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        float val = blorp_vector_read_f32(v, i);
        if (val < min_val) min_val = val;
    }
    return min_val;
}

#ifdef __FLT16_MAX__
_Float16 blorp_vector_max_float16(blorp_Vector* v) {
    if (!v || v->capacity == 0) return (_Float16)0.0;
    _Float16 max_val = blorp_vector_read_f16(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        _Float16 val = blorp_vector_read_f16(v, i);
        if (val > max_val) max_val = val;
    }
    return max_val;
}

_Float16 blorp_vector_min_float16(blorp_Vector* v) {
    if (!v || v->capacity == 0) return (_Float16)0.0;
    _Float16 min_val = blorp_vector_read_f16(v, 0);
    for (long i = 1; i < v->capacity; i++) {
        _Float16 val = blorp_vector_read_f16(v, i);
        if (val < min_val) min_val = val;
    }
    return min_val;
}
#endif

double blorp_vector_norm(blorp_Vector* v) {
    if (!v) return 0.0;
    double sum = 0.0;
    for (long i = 0; i < v->capacity; i++) {
        double value = blorp_vector_read_f64(v, i);
        sum += value * value;
    }
    return sqrt(sum);
}

// Element-wise Int vector addition
blorp_Vector* blorp_vector_add_int(blorp_Vector* a, blorp_Vector* b) {
    return blorp_vector_add_i64(a, b);
}

// Element-wise Float vector addition
blorp_Vector* blorp_vector_add_float(blorp_Vector* a, blorp_Vector* b) {
    return blorp_vector_op(0, 1, a, b);
}

// Scalar broadcast: result[i] = v[i] OP scalar (forward)
// op: 0=add, 1=sub, 2=mul, 3=div
blorp_Vector* blorp_vector_scalar_op_int(int op, blorp_Vector* v, long scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < v->capacity; i++) {
        long val = blorp_vector_read_i64(v, i);
        long vr;
        switch (op) {
            case 0: vr = val + scalar; break;
            case 1: vr = val - scalar; break;
            case 2: vr = val * scalar; break;
            case 3: vr = (scalar == 0) ? 0 : val / scalar; break;
            default: vr = 0;
        }
        blorp_vector_write_i64(result, i, vr);
    }
    return result;
}

#define BLORP_DEFINE_VECTOR_I64_SCALAR(NAME, EXPR) \
blorp_Vector* NAME(const blorp_Vector* v, long scalar) { \
    if (!v) return blorp_vector_new_i64(0); \
    blorp_Vector* result = blorp_vector_new_i64_like_noinit(v); \
    if (blorp_vector_is_i64_raw(v)) { \
        const long* vd = (const long*)v->data; \
        long* rd = (long*)result->data; \
        for (long i = 0; i < v->capacity; i++) { \
            long val = vd[i]; \
            rd[i] = (EXPR); \
        } \
    } else { \
        for (long i = 0; i < v->capacity; i++) { \
            long val = blorp_vector_read_i64(v, i); \
            blorp_vector_write_i64(result, i, (EXPR)); \
        } \
    } \
    return result; \
}

BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_add_i64, val + scalar)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_sub_i64, val - scalar)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_mul_i64, val * scalar)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_div_i64, scalar == 0 ? 0 : val / scalar)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_mod_i64, scalar == 0 ? 0 : val % scalar)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_rev_sub_i64, scalar - val)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_rev_div_i64, val == 0 ? 0 : scalar / val)
BLORP_DEFINE_VECTOR_I64_SCALAR(blorp_vector_scalar_rev_mod_i64, val == 0 ? 0 : scalar % val)

#undef BLORP_DEFINE_VECTOR_I64_SCALAR

#define BLORP_DEFINE_VECTOR_F64_SCALAR(NAME, EXPR) \
blorp_Vector* NAME(const blorp_Vector* v, double scalar) { \
    if (!v) return blorp_vector_new_f64(0); \
    blorp_Vector* result = blorp_vector_new_f64_like_noinit(v); \
    double* rd = (double*)result->data; \
    if (blorp_vector_is_f64_packed(v)) { \
        const double* vd = (const double*)v->data; \
        for (long i = 0; i < v->capacity; i++) { \
            double val = vd[i]; \
            rd[i] = (EXPR); \
        } \
    } else { \
        for (long i = 0; i < v->capacity; i++) { \
            double val = blorp_vector_read_f64(v, i); \
            rd[i] = (EXPR); \
        } \
    } \
    return result; \
}

BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_add_f64, val + scalar)
BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_sub_f64, val - scalar)
BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_mul_f64, val * scalar)
BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_div_f64, scalar == 0.0 ? 0.0 : val / scalar)
BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_rev_sub_f64, scalar - val)
BLORP_DEFINE_VECTOR_F64_SCALAR(blorp_vector_scalar_rev_div_f64, val == 0.0 ? 0.0 : scalar / val)

#undef BLORP_DEFINE_VECTOR_F64_SCALAR

#define BLORP_DEFINE_VECTOR_F32_SCALAR(NAME, EXPR) \
blorp_Vector* NAME(const blorp_Vector* v, float scalar) { \
    if (!v) return blorp_vector_new_f32(0); \
    blorp_Vector* result = blorp_vector_new_f32_like_noinit(v); \
    float* rd = (float*)result->data; \
    if (blorp_vector_is_f32_packed(v)) { \
        const float* vd = (const float*)v->data; \
        for (long i = 0; i < v->capacity; i++) { \
            float val = vd[i]; \
            rd[i] = (EXPR); \
        } \
    } else { \
        for (long i = 0; i < v->capacity; i++) { \
            float val = blorp_vector_read_f32(v, i); \
            rd[i] = (EXPR); \
        } \
    } \
    return result; \
}

BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_add_f32, val + scalar)
BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_sub_f32, val - scalar)
BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_mul_f32, val * scalar)
BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_div_f32, scalar == 0.0f ? 0.0f : val / scalar)
BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_rev_sub_f32, scalar - val)
BLORP_DEFINE_VECTOR_F32_SCALAR(blorp_vector_scalar_rev_div_f32, val == 0.0f ? 0.0f : scalar / val)

#undef BLORP_DEFINE_VECTOR_F32_SCALAR

blorp_Vector* blorp_vector_scalar_op_float(int op, blorp_Vector* v, double scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < v->capacity; i++) {
        double val = blorp_vector_read_f64(v, i);
        double vr;
        switch (op) {
            case 0: vr = val + scalar; break;
            case 1: vr = val - scalar; break;
            case 2: vr = val * scalar; break;
            case 3: vr = (scalar == 0.0) ? 0.0 : val / scalar; break;
            default: vr = 0.0;
        }
        blorp_vector_write_f64(result, i, vr);
    }
    return result;
}

blorp_Vector* blorp_vector_scalar_op_float32(int op, blorp_Vector* v, float scalar) {
    if (!v) return blorp_vector_new_f32(0);
    blorp_Vector* result = blorp_vector_new_f32_like(v);
    for (long i = 0; i < v->capacity; i++) {
        float val = blorp_vector_read_f32(v, i);
        float vr;
        switch (op) {
            case 0: vr = val + scalar; break;
            case 1: vr = val - scalar; break;
            case 2: vr = val * scalar; break;
            case 3: vr = (scalar == 0.0f) ? 0.0f : val / scalar; break;
            default: vr = val;
        }
        blorp_vector_write_f32(result, i, vr);
    }
    return result;
}

blorp_Vector* blorp_vector_scalar_op_float16(int op, blorp_Vector* v, _Float16 scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new(v->capacity);
    result->len = v->len;
    float fs = (float)scalar;
    for (long i = 0; i < v->capacity; i++) {
        float fv = (float)blorp_unbox_float16(v->data[i]);
        float fr;
        switch (op) {
            case 0: fr = fv + fs; break;
            case 1: fr = fv - fs; break;
            case 2: fr = fv * fs; break;
            case 3: fr = (fs == 0.0f) ? 0.0f : fv / fs; break;
            default: fr = fv;
        }
        result->data[i] = blorp_box_float16((_Float16)fr);
    }
    return result;
}

// COW scalar int: result[i] = v[i] OP scalar (in-place when v is unique)
blorp_Vector* blorp_vector_scalar_op_int_cow(int op, blorp_Vector* v, long scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result;
    if (blorp_is_unique(v)) {
        result = v;
    } else {
        result = blorp_vector_new_like(v);
    }
    for (long i = 0; i < v->capacity; i++) {
        long val = blorp_vector_read_i64(v, i);
        long vr;
        switch (op) {
            case 0: vr = val + scalar; break;
            case 1: vr = val - scalar; break;
            case 2: vr = val * scalar; break;
            case 3: vr = (scalar == 0) ? 0 : val / scalar; break;
            default: vr = 0;
        }
        blorp_vector_write_i64(result, i, vr);
    }
    blorp_release_cow_input_if_copied(v, result);
    return result;
}

// COW scalar float: result[i] = v[i] OP scalar (in-place when v is unique)
blorp_Vector* blorp_vector_scalar_op_float_cow(int op, blorp_Vector* v, double scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result;
    if (blorp_is_unique(v)) {
        result = v;
    } else {
        result = blorp_vector_new_like(v);
    }
    for (long i = 0; i < v->capacity; i++) {
        double val = blorp_vector_read_f64(v, i);
        double vr;
        switch (op) {
            case 0: vr = val + scalar; break;
            case 1: vr = val - scalar; break;
            case 2: vr = val * scalar; break;
            case 3: vr = (scalar == 0.0) ? 0.0 : val / scalar; break;
            default: vr = 0.0;
        }
        blorp_vector_write_f64(result, i, vr);
    }
    blorp_release_cow_input_if_copied(v, result);
    return result;
}

// Scalar broadcast reversed: result[i] = scalar OP v[i]
// Needed for non-commutative ops: 2 - v, 10 / v
blorp_Vector* blorp_vector_scalar_op_rev_int(int op, blorp_Vector* v, long scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < v->capacity; i++) {
        long val = blorp_vector_read_i64(v, i);
        long vr;
        switch (op) {
            case 0: vr = scalar + val; break;
            case 1: vr = scalar - val; break;
            case 2: vr = scalar * val; break;
            case 3: vr = (val == 0) ? 0 : scalar / val; break;
            default: vr = 0;
        }
        blorp_vector_write_i64(result, i, vr);
    }
    return result;
}

blorp_Vector* blorp_vector_scalar_op_rev_float(int op, blorp_Vector* v, double scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < v->capacity; i++) {
        double val = blorp_vector_read_f64(v, i);
        double vr;
        switch (op) {
            case 0: vr = scalar + val; break;
            case 1: vr = scalar - val; break;
            case 2: vr = scalar * val; break;
            case 3: vr = (val == 0.0) ? 0.0 : scalar / val; break;
            default: vr = 0.0;
        }
        blorp_vector_write_f64(result, i, vr);
    }
    return result;
}

// Reverse scalar/vector op for Float32: computes [scalar OP v[i]] for each
// element. Mirrors blorp_vector_scalar_op_rev_float; needed for non-
// commutative scalar-on-left forms ([10.0 - v], [8.0 / v]) on Float32
// vectors. The forward variant lives at blorp_vector_scalar_op_float32.
blorp_Vector* blorp_vector_scalar_op_rev_float32(int op, blorp_Vector* v, float scalar) {
    if (!v) return blorp_vector_new_f32(0);
    blorp_Vector* result = blorp_vector_new_f32_like(v);
    for (long i = 0; i < v->capacity; i++) {
        float val = blorp_vector_read_f32(v, i);
        float vr;
        switch (op) {
            case 0: vr = scalar + val; break;
            case 1: vr = scalar - val; break;
            case 2: vr = scalar * val; break;
            case 3: vr = (val == 0.0f) ? 0.0f : scalar / val; break;
            default: vr = 0.0f;
        }
        blorp_vector_write_f32(result, i, vr);
    }
    return result;
}

// Reverse scalar/vector op for Float16. Same shape as the Float32
// variant but goes through the box/unbox helpers since Float16 storage
// is non-trivial.
blorp_Vector* blorp_vector_scalar_op_rev_float16(int op, blorp_Vector* v, _Float16 scalar) {
    if (!v) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new(v->capacity);
    result->len = v->len;
    float fs = (float)scalar;
    for (long i = 0; i < v->capacity; i++) {
        float fv = (float)blorp_unbox_float16(v->data[i]);
        float fr;
        switch (op) {
            case 0: fr = fs + fv; break;
            case 1: fr = fs - fv; break;
            case 2: fr = fs * fv; break;
            case 3: fr = (fv == 0.0f) ? 0.0f : fs / fv; break;
            default: fr = 0.0f;
        }
        result->data[i] = blorp_box_float16((_Float16)fr);
    }
    return result;
}

// Slice a vector from start (inclusive) to end (exclusive)
blorp_Vector* blorp_vector_slice(blorp_Vector* v, long start, long end) {
    if (!v || start >= end || start < 0 || end > v->len) return blorp_vector_new(0);
    long new_len = end - start;
    int8_t es = v->elem_size;
    if (es < 0) {
        // Sub-byte packed: element-by-element copy (start may not be byte-aligned)
        blorp_Vector* result = blorp_vector_new_packed(new_len, es);
        for (long i = 0; i < new_len; i++) {
            blorp_packed_set(result, i, blorp_packed_get(v, start + i));
        }
        return result;
    }
    long byte_es = (long)es;
    blorp_Vector* result = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(new_len, byte_es)));
    result->len = new_len;
    result->capacity = new_len;
    result->elem_release = v->elem_release;
    result->elem_size = es;
    result->storage_mode = v->storage_mode;
    if (result->elem_release) {
        BLORP_SET_DESTRUCTOR(result, blorp_vector_destroy);
    }
    memcpy(result->data, (char*)v->data + start * byte_es, new_len * byte_es);
    if (result->elem_release) {
        for (long i = 0; i < new_len; i++) {
            if (result->data[i]) blorp_retain(result->data[i]);
        }
    }
    return result;
}

// Element-wise exp() on float vector — returns new vector
blorp_Vector* blorp_vector_exp(blorp_Vector* v) {
    if (!v) return blorp_vector_new(0);
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < len; i++) {
        double val = blorp_vector_read_f64(v, i);
        double r = exp(val);
        blorp_vector_write_f64(result, i, r);
    }
    return result;
}

// Element-wise log() on float vector — returns new vector
blorp_Vector* blorp_vector_log(blorp_Vector* v) {
    if (!v) return blorp_vector_new(0);
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < len; i++) {
        double val = blorp_vector_read_f64(v, i);
        double r = log(val);
        blorp_vector_write_f64(result, i, r);
    }
    return result;
}

// Element-wise sqrt() on float vector — returns new vector
// Element-wise abs() on float vector
blorp_Vector* blorp_vector_abs(blorp_Vector* v) {
    if (!v) return blorp_vector_new(0);
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < len; i++) {
        double val = blorp_vector_read_f64(v, i);
        double r = fabs(val);
        blorp_vector_write_f64(result, i, r);
    }
    return result;
}

blorp_Vector* blorp_vector_sqrt(blorp_Vector* v) {
    if (!v) return blorp_vector_new(0);
    long len = v->capacity;
    blorp_Vector* result = blorp_vector_new_like(v);
    for (long i = 0; i < len; i++) {
        double val = blorp_vector_read_f64(v, i);
        double r = sqrt(fabs(val));
        blorp_vector_write_f64(result, i, r);
    }
    return result;
}

// Float32/Float16 element-wise exp/log/sqrt
#define DEFINE_VECTOR_UNARY_F32(NAME, FUNC) \
blorp_Vector* blorp_vector_##NAME##_float32(blorp_Vector* v) { \
    if (!v) return blorp_vector_new_f32(0); \
    blorp_Vector* result = blorp_vector_new_f32_like(v); \
    for (long i = 0; i < v->capacity; i++) \
        blorp_vector_write_f32(result, i, FUNC(blorp_vector_read_f32(v, i))); \
    return result; \
}
#define DEFINE_VECTOR_UNARY_F16(NAME, FUNC) \
blorp_Vector* blorp_vector_##NAME##_float16(blorp_Vector* v) { \
    if (!v) return blorp_vector_new(0); \
    blorp_Vector* result = blorp_vector_new(v->capacity); \
    result->len = v->len; \
    for (long i = 0; i < v->capacity; i++) \
        result->data[i] = blorp_box_float16((_Float16)FUNC((float)blorp_unbox_float16(v->data[i]))); \
    return result; \
}
DEFINE_VECTOR_UNARY_F32(exp, expf)
DEFINE_VECTOR_UNARY_F32(log, logf)
DEFINE_VECTOR_UNARY_F32(sqrt, sqrtf)
DEFINE_VECTOR_UNARY_F16(exp, expf)
DEFINE_VECTOR_UNARY_F16(log, logf)
DEFINE_VECTOR_UNARY_F16(sqrt, sqrtf)

// Vector equality: compare all elements, return 1 (true) or 0 (false)
// Unified vector equality: elem_type 0=Int, 1=Float64, 2=Float32, 3=Float16
long blorp_vector_eq(int elem_type, blorp_Vector* a, blorp_Vector* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->capacity != b->capacity) return 0;
    if (elem_type == 0) {
        for (long i = 0; i < a->capacity; i++)
            if (blorp_vector_read_i64(a, i) != blorp_vector_read_i64(b, i)) return 0;
    } else if (elem_type == 1) {
        for (long i = 0; i < a->capacity; i++) {
            double va = blorp_vector_read_f64(a, i);
            double vb = blorp_vector_read_f64(b, i);
            if (va != vb) return 0;
        }
    } else if (elem_type == 2) {
        for (long i = 0; i < a->capacity; i++)
            if (blorp_vector_read_f32(a, i) != blorp_vector_read_f32(b, i)) return 0;
    } else if (elem_type == 3) {
        for (long i = 0; i < a->capacity; i++)
            if (blorp_unbox_float16(a->data[i]) != blorp_unbox_float16(b->data[i])) return 0;
    }
    return 1;
}

// ============================================================================
// Float32 Vector Operations (packed float storage, 4 bytes per element)
// ============================================================================

// Element-wise Float32 vector operation
float blorp_vector_norm_float32(blorp_Vector* v) {
    if (!v) return 0.0f;
    float sum = 0.0f;
    for (long i = 0; i < v->capacity; i++) {
        float val = blorp_vector_read_f32(v, i);
        sum += val * val;
    }
    return sqrtf(sum);
}

// Float32 vector to_string
blorp_String* blorp_vector_to_string_float32(blorp_Vector* v) {
    if (!v || v->capacity == 0) {
        return blorp_string_literal("{}");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(v->capacity, 24), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '{';
    for (long i = 0; i < v->capacity; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        pos += snprintf(buf + pos, buf_size - pos, "%.9g", (double)blorp_vector_read_f32(v, i));
    }
    buf[pos++] = '}';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

static blorp_Vector* blorp_vector_set_cow_f32_result(blorp_Vector* arr, long index, float value) {
    if (!arr || index < 0 || index >= arr->len) {
        return NULL;
    }
    blorp_Vector* result = blorp_is_unique(arr) ? arr : blorp_vector_copy(arr);
    if (result != arr) blorp_release((blorp_Object*)arr);
    blorp_vector_write_f32(result, index, value);
    return result;
}

blorp_Vector* blorp_vector_set_cow_nullable_f32(blorp_Vector* arr, long index, float value) {
    return blorp_vector_set_cow_f32_result(arr, index, value);
}

// Float32 COW set_index
blorp_Option* blorp_vector_set_cow_f32(blorp_Vector* arr, long index, float value) {
    blorp_Vector* result = blorp_vector_set_cow_f32_result(arr, index, value);
    if (!result) return blorp_option_none();
    blorp_Option* opt = blorp_option_some((void*)result);
    opt->release_mask = 1UL;
    return opt;
}

#ifdef __FLT16_MAX__
// ============================================================================
// Float16 Vector Operations (void*-boxed storage, 2-byte _Float16 in 8-byte void*)
// ============================================================================

_Float16 blorp_vector_norm_float16(blorp_Vector* v) {
    if (!v) return (_Float16)0.0;
    float sum = 0.0f;
    for (long i = 0; i < v->capacity; i++) {
        float val = (float)blorp_vector_read_f16(v, i);
        sum += val * val;
    }
    return (_Float16)sqrtf(sum);
}

// Float16 vector to_string
blorp_String* blorp_vector_to_string_float16(blorp_Vector* v) {
    if (!v || v->capacity == 0) {
        return blorp_string_literal("{}");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(v->capacity, 24), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '{';
    for (long i = 0; i < v->capacity; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        float val = (float)blorp_unbox_float16(v->data[i]);
        pos += snprintf(buf + pos, buf_size - pos, "%.4g", (double)val);
    }
    buf[pos++] = '}';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

#endif // __FLT16_MAX__

// Vector to_string: format as {1, 2, 3}
blorp_String* blorp_vector_to_string_int(blorp_Vector* v) {
    if (!v || v->capacity == 0) {
        return blorp_string_literal("{}");
    }
    long is_2d = (v->len > 0 && v->capacity > v->len);
    long cols = is_2d ? v->capacity / v->len : 0;
    // Buffer: each int ~20 chars + separators + nested braces
    size_t buf_size = blorp_checked_add(blorp_checked_mul(v->capacity, 24), is_2d ? v->len * 4 + 10 : 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '{';
    if (is_2d) {
        for (long r = 0; r < v->len; r++) {
            if (r > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
            buf[pos++] = '{';
            for (long c = 0; c < cols; c++) {
                if (c > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
                pos += snprintf(buf + pos, buf_size - pos, "%ld", blorp_vector_read_i64(v, r * cols + c));
            }
            buf[pos++] = '}';
        }
    } else {
        for (long i = 0; i < v->capacity; i++) {
            if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
            pos += snprintf(buf + pos, buf_size - pos, "%ld", blorp_vector_read_i64(v, i));
        }
    }
    buf[pos++] = '}';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

blorp_String* blorp_vector_to_string_float(blorp_Vector* v) {
    if (!v || v->capacity == 0) {
        return blorp_string_literal("{}");
    }
    long is_2d = (v->len > 0 && v->capacity > v->len);
    long cols = is_2d ? v->capacity / v->len : 0;
    size_t buf_size = blorp_checked_add(blorp_checked_mul(v->capacity, 32), is_2d ? v->len * 4 + 10 : 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '{';
    if (is_2d) {
        for (long r = 0; r < v->len; r++) {
            if (r > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
            buf[pos++] = '{';
            for (long c = 0; c < cols; c++) {
                if (c > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
                double val = blorp_vector_read_f64(v, r * cols + c);
                pos += snprintf(buf + pos, buf_size - pos, "%.17g", val);
            }
            buf[pos++] = '}';
        }
    } else {
        for (long i = 0; i < v->capacity; i++) {
            if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
            double val = blorp_vector_read_f64(v, i);
            pos += snprintf(buf + pos, buf_size - pos, "%.17g", val);
        }
    }
    buf[pos++] = '}';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

// List to_string: format as [1, 2, 3]
blorp_String* blorp_list_to_string_int(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(list->len, 24), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        pos += snprintf(buf + pos, buf_size - pos, "%ld", (long)blorp_list_get(list, i));
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

blorp_String* blorp_list_to_string_float(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(list->len, 32), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        double val;
        void* raw = blorp_list_get(list, i);
        memcpy(&val, &raw, sizeof(double));
        pos += snprintf(buf + pos, buf_size - pos, "%.17g", val);
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

blorp_String* blorp_list_to_string_float32(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(list->len, 32), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        float val = blorp_unbox_float32(blorp_list_get(list, i));
        pos += snprintf(buf + pos, buf_size - pos, "%g", (double)val);
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

#ifdef __FLT16_MAX__
blorp_String* blorp_list_to_string_float16(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    size_t buf_size = blorp_checked_add(blorp_checked_mul(list->len, 32), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        _Float16 val = blorp_unbox_float16(blorp_list_get(list, i));
        pos += snprintf(buf + pos, buf_size - pos, "%g", (double)val);
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}
#endif // __FLT16_MAX__

blorp_String* blorp_list_to_string_string(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    // Each string: quotes + content + ", " separator
    size_t buf_size = 3; // "[]" + null
    for (long i = 0; i < list->len; i++) {
        blorp_String* s = (blorp_String*)blorp_list_get(list, i);
        buf_size = blorp_checked_add(buf_size, s ? s->len + 4 : 8); // quotes + ", " + content or "null"
    }
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        blorp_String* s = (blorp_String*)blorp_list_get(list, i);
        if (s) {
            pos += snprintf(buf + pos, buf_size - pos, "\"%s\"", s->data);
        } else {
            pos += snprintf(buf + pos, buf_size - pos, "\"\"");
        }
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

blorp_String* blorp_list_to_string_bool(blorp_List* list) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    // "True" = 4, "False" = 5, ", " = 2 each
    size_t buf_size = blorp_checked_add(blorp_checked_mul(list->len, 8), 3);
    char* buf = (char*)blorp_malloc_checked(buf_size);
    long pos = 0;
    buf[pos++] = '[';
    for (long i = 0; i < list->len; i++) {
        if (i > 0) { buf[pos++] = ','; buf[pos++] = ' '; }
        const char* val = (long)blorp_list_get(list, i) ? "True" : "False";
        pos += snprintf(buf + pos, buf_size - pos, "%s", val);
    }
    buf[pos++] = ']';
    buf[pos] = '\0';
    blorp_String* result = blorp_string_from_buf(buf, pos);
    free(buf);
    return result;
}

// List to_string with callback: format as [elem_to_str(data[0]), elem_to_str(data[1]), ...]
// Used for List[Tuple] and other compound element types where codegen provides the formatter.
blorp_String* blorp_list_to_string_cb(blorp_List* list, blorp_String* (*elem_to_str)(void*)) {
    if (!list || list->len == 0) {
        return blorp_string_literal("[]");
    }
    // Build by concatenating element strings
    blorp_String* result = blorp_string_literal("[");
    for (long i = 0; i < list->len; i++) {
        if (i > 0) {
            blorp_String* sep = blorp_string_literal(", ");
            result = blorp_string_concat_consume(result, sep);
        }
        blorp_String* elem_str = elem_to_str(blorp_list_get(list, i));
        result = blorp_string_concat_consume(result, elem_str);
    }
    blorp_String* close = blorp_string_literal("]");
    result = blorp_string_concat_consume(result, close);
    return result;
}

// (removed blorp_arange — now IR intrinsic)
// (removed blorp_linspace — now IR intrinsic)

// cross product (3D vectors only)
blorp_Vector* blorp_vector_cross_float(blorp_Vector* a, blorp_Vector* b) {
    if (!a || !b || a->capacity < 3 || b->capacity < 3) {
        return blorp_vector_new_f64(3);
    }
    blorp_Vector* result = blorp_vector_new_f64(3);
    double ax = blorp_vector_read_f64(a, 0);
    double ay = blorp_vector_read_f64(a, 1);
    double az = blorp_vector_read_f64(a, 2);
    double bx = blorp_vector_read_f64(b, 0);
    double by = blorp_vector_read_f64(b, 1);
    double bz = blorp_vector_read_f64(b, 2);
    double rx = ay * bz - az * by;
    double ry = az * bx - ax * bz;
    double rz = ax * by - ay * bx;
    blorp_vector_write_f64(result, 0, rx);
    blorp_vector_write_f64(result, 1, ry);
    blorp_vector_write_f64(result, 2, rz);
    return result;
}

// Slice a row from a multi-dimensional tensor (flat row-major storage)
// Returns a new vector containing row_size elements starting at row_index * row_size
// result_first_dim: the len of the result (= row_size for 1D result, = next dim for N-D result)
blorp_Vector* blorp_tensor_slice_row(blorp_Vector* tensor, long row_index, long row_size, long result_first_dim) {
    if (!tensor || row_size <= 0) return blorp_vector_new(0);
    if (row_index < 0 || row_index >= tensor->len) return blorp_vector_new(0);
    long offset = row_index * row_size;
    if (offset + row_size > tensor->capacity) return blorp_vector_new(0);
    int8_t es = tensor->elem_size;
    if (es < 0) {
        // Sub-byte packed: element-by-element copy (offset may not be byte-aligned)
        blorp_Vector* result = blorp_vector_new_packed(row_size, es);
        result->len = result_first_dim;
        for (long i = 0; i < row_size; i++) {
            blorp_packed_set(result, i, blorp_packed_get(tensor, offset + i));
        }
        return result;
    }
    long byte_es = (long)es;
    blorp_Vector* result = (blorp_Vector*)blorp_alloc(blorp_checked_add(sizeof(blorp_Vector), blorp_checked_mul(row_size, byte_es)));
    result->len = result_first_dim;
    result->capacity = row_size;
    result->elem_release = tensor->elem_release;
    result->elem_size = es;
    result->storage_mode = tensor->storage_mode;
    if (result->elem_release) {
        BLORP_SET_DESTRUCTOR(result, blorp_vector_destroy);
    }
    memcpy(result->data, (char*)tensor->data + offset * byte_es, row_size * byte_es);
    if (result->elem_release) {
        for (long i = 0; i < row_size; i++) {
            if (result->data[i]) blorp_retain(result->data[i]);
        }
    }
    return result;
}

// Matrix multiplication (Int): C[M,N] = A[M,K] * B[K,N]
// All tensors use flat row-major storage; m, k, n are dimension params from codegen
blorp_Vector* blorp_tensor_matmul_int(blorp_Vector* a, blorp_Vector* b, long m, long k, long n) {
    if (!a || !b) return blorp_tensor_new_i64(m, m * n);
    if (m * k > a->capacity || k * n > b->capacity) return blorp_tensor_new_i64(m, m * n);
    blorp_Vector* result = blorp_tensor_new_i64(m, m * n);
    // ikj loop order for cache locality: both result and b accessed sequentially
    for (long i = 0; i < m; i++) {
        for (long p = 0; p < k; p++) {
            long va = blorp_vector_read_i64(a, i * k + p);
            for (long j = 0; j < n; j++) {
                long idx = i * n + j;
                long cur = blorp_vector_read_i64(result, idx);
                cur += va * blorp_vector_read_i64(b, p * n + j);
                blorp_vector_write_i64(result, idx, cur);
            }
        }
    }
    return result;
}

// Matrix multiplication (Float): C[M,N] = A[M,K] * B[K,N]
blorp_Vector* blorp_tensor_matmul_float(blorp_Vector* a, blorp_Vector* b, long m, long k, long n) {
    if (!a || !b) return blorp_tensor_new_f64(m, m * n);
    if (m * k > a->capacity || k * n > b->capacity) return blorp_tensor_new_f64(m, m * n);
    blorp_Vector* result = blorp_tensor_new_f64(m, m * n);
    // ikj loop order for cache locality: both result and b accessed sequentially
    for (long i = 0; i < m; i++) {
        for (long p = 0; p < k; p++) {
            double va = blorp_vector_read_f64(a, i * k + p);
            for (long j = 0; j < n; j++) {
                long idx = i * n + j;
                double cur = blorp_vector_read_f64(result, idx);
                double vb = blorp_vector_read_f64(b, p * n + j);
                cur += va * vb;
                blorp_vector_write_f64(result, idx, cur);
            }
        }
    }
    return result;
}

// Matrix multiplication (Float32): C[M,N] = A[M,K] * B[K,N]
// Uses packed float storage (4 bytes per element)
blorp_Vector* blorp_tensor_matmul_float32(blorp_Vector* a, blorp_Vector* b, long m, long k, long n) {
    if (!a || !b) return blorp_tensor_new_f32(m, m * n);
    if (m * k > a->capacity || k * n > b->capacity) return blorp_tensor_new_f32(m, m * n);
    blorp_Vector* result = blorp_tensor_new_f32(m, m * n);
    // ikj loop order for cache locality
    for (long i = 0; i < m; i++) {
        for (long p = 0; p < k; p++) {
            float va = blorp_vector_read_f32(a, i * k + p);
            for (long j = 0; j < n; j++) {
                long idx = i * n + j;
                float cur = blorp_vector_read_f32(result, idx);
                cur += va * blorp_vector_read_f32(b, p * n + j);
                blorp_vector_write_f32(result, idx, cur);
            }
        }
    }
    return result;
}

// Matrix transpose: result[j*rows+i] = src[i*cols+j]
// Type-generic (operates on void* elements)
blorp_Vector* blorp_tensor_transpose(blorp_Vector* mat, long rows, long cols) {
    if (!mat) return blorp_tensor_new(cols, rows * cols);
    if (rows * cols > mat->capacity) {
        return blorp_vector_is_i64_raw(mat)
            ? blorp_tensor_new_i64(cols, rows * cols)
            : blorp_tensor_new(cols, rows * cols);
    }
    if (blorp_vector_is_i64_raw(mat)) {
        blorp_Vector* result = blorp_tensor_new_i64(cols, rows * cols);
        for (long i = 0; i < rows; i++) {
            for (long j = 0; j < cols; j++) {
                blorp_vector_write_i64(result, j * rows + i, blorp_vector_read_i64(mat, i * cols + j));
            }
        }
        return result;
    }
    blorp_Vector* result = blorp_tensor_new(cols, rows * cols);
    for (long i = 0; i < rows; i++) {
        for (long j = 0; j < cols; j++) {
            result->data[j * rows + i] = mat->data[i * cols + j];
        }
    }
    return result;
}

// Matrix-vector multiply (Float): y[i] = sum_j(W[i*n+j] * x[j])
blorp_Vector* blorp_tensor_matvec_float(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || n > x->capacity) return blorp_vector_new_f64(m);
    blorp_Vector* result = blorp_vector_new_f64(m);
    for (long i = 0; i < m; i++) {
        double acc = 0.0;
        for (long j = 0; j < n; j++) {
            double wv = blorp_vector_read_f64(w, i * n + j);
            double xv = blorp_vector_read_f64(x, j);
            acc += wv * xv;
        }
        blorp_vector_write_f64(result, i, acc);
    }
    return result;
}

// Matrix-vector multiply (Int)
blorp_Vector* blorp_tensor_matvec_int(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || n > x->capacity) return blorp_vector_new_i64(m);
    blorp_Vector* result = blorp_vector_new_i64(m);
    for (long i = 0; i < m; i++) {
        long acc = 0;
        for (long j = 0; j < n; j++) {
            acc += blorp_vector_read_i64(w, i * n + j) * blorp_vector_read_i64(x, j);
        }
        blorp_vector_write_i64(result, i, acc);
    }
    return result;
}

// Matrix-vector multiply (Float32)
blorp_Vector* blorp_tensor_matvec_float32(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || n > x->capacity) return blorp_vector_new_f32(m);
    blorp_Vector* result = blorp_vector_new_f32(m);
    for (long i = 0; i < m; i++) {
        float acc = 0.0f;
        for (long j = 0; j < n; j++) {
            acc += blorp_vector_read_f32(w, i * n + j) * blorp_vector_read_f32(x, j);
        }
        blorp_vector_write_f32(result, i, acc);
    }
    return result;
}

// Transpose-matvec: result[j] = sum_i(W[i,j] * x[i]) = W^T * x
// W is [m, n], x is [m], result is [n]. Avoids allocating a transposed matrix.
blorp_Vector* blorp_tensor_matvec_t_float(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || m > x->capacity) return blorp_vector_new_f64(n);
    blorp_Vector* result = blorp_vector_new_f64(n);
    for (long j = 0; j < n; j++) {
        double acc = 0.0;
        for (long i = 0; i < m; i++) {
            double wv = blorp_vector_read_f64(w, i * n + j);
            double xv = blorp_vector_read_f64(x, i);
            acc += wv * xv;
        }
        blorp_vector_write_f64(result, j, acc);
    }
    return result;
}

blorp_Vector* blorp_tensor_matvec_t_int(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || m > x->capacity) return blorp_vector_new_i64(n);
    blorp_Vector* result = blorp_vector_new_i64(n);
    for (long j = 0; j < n; j++) {
        long acc = 0;
        for (long i = 0; i < m; i++) {
            acc += blorp_vector_read_i64(w, i * n + j) * blorp_vector_read_i64(x, i);
        }
        blorp_vector_write_i64(result, j, acc);
    }
    return result;
}

blorp_Vector* blorp_tensor_matvec_t_float32(blorp_Vector* w, blorp_Vector* x, long m, long n) {
    if (!w || !x || m * n > w->capacity || m > x->capacity) return blorp_vector_new_f32(n);
    blorp_Vector* result = blorp_vector_new_f32(n);
    for (long j = 0; j < n; j++) {
        float acc = 0.0f;
        for (long i = 0; i < m; i++) {
            acc += blorp_vector_read_f32(w, i * n + j) * blorp_vector_read_f32(x, i);
        }
        blorp_vector_write_f32(result, j, acc);
    }
    return result;
}

// Outer product (Float): result[i*n+j] = a[i] * b[j]
blorp_Vector* blorp_tensor_outer_float(blorp_Vector* a, blorp_Vector* b, long m, long n) {
    if (!a || !b || m > a->capacity || n > b->capacity) return blorp_tensor_new_f64(m, m * n);
    blorp_Vector* result = blorp_tensor_new_f64(m, m * n);
    for (long i = 0; i < m; i++) {
        double va = blorp_vector_read_f64(a, i);
        for (long j = 0; j < n; j++) {
            double vb = blorp_vector_read_f64(b, j);
            blorp_vector_write_f64(result, i * n + j, va * vb);
        }
    }
    return result;
}

// Outer product (Int)
blorp_Vector* blorp_tensor_outer_int(blorp_Vector* a, blorp_Vector* b, long m, long n) {
    if (!a || !b || m > a->capacity || n > b->capacity) return blorp_tensor_new_i64(m, m * n);
    blorp_Vector* result = blorp_tensor_new_i64(m, m * n);
    for (long i = 0; i < m; i++) {
        long va = blorp_vector_read_i64(a, i);
        for (long j = 0; j < n; j++) {
            blorp_vector_write_i64(result, i * n + j, va * blorp_vector_read_i64(b, j));
        }
    }
    return result;
}

// Outer product (Float32)
blorp_Vector* blorp_tensor_outer_float32(blorp_Vector* a, blorp_Vector* b, long m, long n) {
    if (!a || !b || m > a->capacity || n > b->capacity) return blorp_tensor_new_f32(m, m * n);
    blorp_Vector* result = blorp_tensor_new_f32(m, m * n);
    for (long i = 0; i < m; i++) {
        float va = blorp_vector_read_f32(a, i);
        for (long j = 0; j < n; j++) {
            blorp_vector_write_f32(result, i * n + j, va * blorp_vector_read_f32(b, j));
        }
    }
    return result;
}

// Generic length() function
long blorp_length(void* collection) {
    if (!collection) return 0;
    blorp_List* list = (blorp_List*)collection;
    return list->len;
}

// ============================================================================
// Bytes (Binary Buffer) Operations
// ============================================================================

typedef struct {
    blorp_Object header;
    long len;
    long capacity;
    unsigned char data[];
} blorp_Bytes;

blorp_Bytes* blorp_bytes_new(long capacity) {
    if (capacity < 0) capacity = 0;
    long alloc_cap = capacity < 16 ? 16 : capacity;
    blorp_Bytes* b = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + alloc_cap);
    b->len = capacity;  // requested size, zero-filled
    b->capacity = alloc_cap;
    memset(b->data, 0, alloc_cap);
    return b;
}

// IR intrinsic: allocate empty bytes buffer with capacity (no zero-fill, len=0).
blorp_Bytes* blorp_bytes_alloc(long capacity) {
    if (capacity < 1) capacity = 1;
    blorp_Bytes* b = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + capacity);
    b->len = 0;
    b->capacity = capacity;
    return b;
}

// IR intrinsic: COW check — if shared, copy; if unique, return as-is.
blorp_Bytes* blorp_bytes_cow(blorp_Bytes* b) {
    if (!b) return blorp_bytes_alloc(1);
    if (blorp_is_unique(b)) return b;
    blorp_Bytes* copy = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + b->capacity);
    copy->len = b->len;
    copy->capacity = b->capacity;
    memcpy(copy->data, b->data, b->len);
    blorp_release(b);
    return copy;
}

// FFI copy: create independent deep copy of a bytes buffer (refcount = 1).
blorp_Bytes* blorp_bytes_copy_ffi(blorp_Bytes* src) {
    if (!src) return blorp_bytes_new(0);
    long cap = src->capacity < src->len ? src->len : src->capacity;
    if (cap < 1) cap = 1;
    blorp_Bytes* copy = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + cap);
    copy->len = src->len;
    copy->capacity = cap;
    if (src->len > 0) {
        memcpy(copy->data, src->data, src->len);
    }
    if (cap > src->len) {
        memset(copy->data + src->len, 0, cap - src->len);
    }
    return copy;
}

blorp_Bytes* blorp_bytes_from_string(blorp_String* s) {
    if (!s || s->len == 0) return blorp_bytes_new(0);
    blorp_Bytes* b = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + s->len);
    b->len = s->len;
    b->capacity = s->len;
    memcpy(b->data, s->data, s->len);
    return b;
}

blorp_String* blorp_bytes_to_string(blorp_Bytes* b) {
    if (!b || b->len == 0) return __blorp_empty_str;
    blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + b->len + 1);
    s->len = b->len;
    s->capacity = b->len;
    memcpy(s->data, b->data, b->len);
    s->data[b->len] = '\0';
    return s;
}

// (removed blorp_bytes_get — now IR intrinsic)
// (removed blorp_bytes_set_cow — now IR intrinsic)
// (removed blorp_bytes_slice — now IR intrinsic)
// (removed blorp_bytes_append — now IR intrinsic)
// (removed blorp_bytes_fill — now IR intrinsic)
// (removed blorp_bytes_blit — now IR intrinsic)
// (removed blorp_bytes_index_of — now IR intrinsic)
// (removed blorp_bytes_index_of_opt — now IR intrinsic)
// (removed blorp_bytes_concat — now std source)
// (removed blorp_bytes_read/write integer helpers — now std source)
// (removed blorp_bytes_to_hex — now std source)

// ============================================================================
// Hex Decoding
// ============================================================================

static blorp_Bytes* blorp_bytes_from_hex_result(const blorp_String* s) {
    if (!s || s->len == 0) {
        return blorp_bytes_new(0);
    }
    if (s->len % 2 != 0) {
        return NULL;
    }
    long byte_len = s->len / 2;
    blorp_Bytes* result = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + byte_len);
    result->len = byte_len;
    result->capacity = byte_len;
    for (long i = 0; i < byte_len; i++) {
        unsigned char hi = (unsigned char)s->data[i * 2];
        unsigned char lo = (unsigned char)s->data[i * 2 + 1];
        int h, l;
        if (hi >= '0' && hi <= '9') h = hi - '0';
        else if (hi >= 'a' && hi <= 'f') h = hi - 'a' + 10;
        else if (hi >= 'A' && hi <= 'F') h = hi - 'A' + 10;
        else {
            blorp_release((void*)result);
            return NULL;
        }
        if (lo >= '0' && lo <= '9') l = lo - '0';
        else if (lo >= 'a' && lo <= 'f') l = lo - 'a' + 10;
        else if (lo >= 'A' && lo <= 'F') l = lo - 'A' + 10;
        else {
            blorp_release((void*)result);
            return NULL;
        }
        result->data[i] = (unsigned char)((h << 4) | l);
    }
    return result;
}

blorp_Bytes* blorp_bytes_from_hex_nullable(const blorp_String* s) {
    return blorp_bytes_from_hex_result(s);
}

// from_hex: parse hex string to Bytes. Returns NULL for invalid input.
blorp_Bytes* blorp_bytes_from_hex(const blorp_String* s) {
    return blorp_bytes_from_hex_result(s);
}

// ============================================================================
// UTF-8 Encoding/Decoding
// ============================================================================

// encode_utf8: encode a List[Char] (List[int32_t codepoints]) to Bytes
blorp_Bytes* blorp_encode_utf8(blorp_List* chars) {
    if (!chars || chars->len == 0) return blorp_bytes_new(0);
    // Worst case: 4 bytes per codepoint
    size_t max_len = blorp_checked_mul(chars->len, 4);
    blorp_Bytes* result = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + max_len);
    result->capacity = max_len;
    long pos = 0;
    for (long i = 0; i < chars->len; i++) {
        int32_t cp = (int32_t)(long)blorp_list_get(chars, i);
        if (cp < 0) cp = 0xFFFD; // replacement character for invalid
        if (cp <= 0x7F) {
            result->data[pos++] = (unsigned char)cp;
        } else if (cp <= 0x7FF) {
            result->data[pos++] = (unsigned char)(0xC0 | (cp >> 6));
            result->data[pos++] = (unsigned char)(0x80 | (cp & 0x3F));
        } else if (cp <= 0xFFFF) {
            result->data[pos++] = (unsigned char)(0xE0 | (cp >> 12));
            result->data[pos++] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
            result->data[pos++] = (unsigned char)(0x80 | (cp & 0x3F));
        } else if (cp <= 0x10FFFF) {
            result->data[pos++] = (unsigned char)(0xF0 | (cp >> 18));
            result->data[pos++] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
            result->data[pos++] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
            result->data[pos++] = (unsigned char)(0x80 | (cp & 0x3F));
        } else {
            // Replacement character U+FFFD
            result->data[pos++] = 0xEF;
            result->data[pos++] = 0xBF;
            result->data[pos++] = 0xBD;
        }
    }
    result->len = pos;
    return result;
}

static blorp_List* blorp_decode_utf8_result(blorp_Bytes* b) {
    if (!b || b->len == 0) {
        return blorp_list_new_inline(0, 4);
    }
    blorp_List* result = blorp_list_new_inline(b->len, 4); // at most b->len codepoints
    long i = 0;
    while (i < b->len) {
        unsigned char byte = b->data[i];
        int32_t cp;
        int expected;
        if (byte <= 0x7F) {
            cp = byte;
            expected = 0;
        } else if ((byte & 0xE0) == 0xC0) {
            cp = byte & 0x1F;
            expected = 1;
        } else if ((byte & 0xF0) == 0xE0) {
            cp = byte & 0x0F;
            expected = 2;
        } else if ((byte & 0xF8) == 0xF0) {
            cp = byte & 0x07;
            expected = 3;
        } else {
            blorp_release((void*)result);
            return NULL;
        }
        for (int j = 0; j < expected; j++) {
            i++;
            if (i >= b->len || (b->data[i] & 0xC0) != 0x80) {
                blorp_release((void*)result);
                return NULL;
            }
            cp = (cp << 6) | (b->data[i] & 0x3F);
        }
        result = blorp_list_append(result, (void*)(long)cp);
        i++;
    }
    return result;
}

blorp_List* blorp_decode_utf8_nullable(blorp_Bytes* b) {
    return blorp_decode_utf8_result(b);
}

// decode_utf8: decode Bytes to List[Char] (List[int32_t codepoints])
// Returns NULL for invalid UTF-8.
blorp_List* blorp_decode_utf8(blorp_Bytes* b) {
    return blorp_decode_utf8_result(b);
}

// ============================================================================
// Base64 Encoding/Decoding (RFC 4648)
// ============================================================================

static const char blorp_b64_encode_table[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// base64_encode: encode String to base64 String
blorp_String* blorp_base64_encode(const blorp_String* s) {
    if (!s || s->len == 0) return __blorp_empty_str;
    long out_len = ((s->len + 2) / 3) * 4;
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + out_len + 1);
    result->len = out_len;
    result->capacity = out_len;
    long j = 0;
    for (long i = 0; i < s->len; i += 3) {
        unsigned char b0 = (unsigned char)s->data[i];
        unsigned char b1 = (i + 1 < s->len) ? (unsigned char)s->data[i + 1] : 0;
        unsigned char b2 = (i + 2 < s->len) ? (unsigned char)s->data[i + 2] : 0;
        result->data[j++] = blorp_b64_encode_table[b0 >> 2];
        result->data[j++] = blorp_b64_encode_table[((b0 & 0x03) << 4) | (b1 >> 4)];
        result->data[j++] = (i + 1 < s->len) ? blorp_b64_encode_table[((b1 & 0x0F) << 2) | (b2 >> 6)] : '=';
        result->data[j++] = (i + 2 < s->len) ? blorp_b64_encode_table[b2 & 0x3F] : '=';
    }
    result->data[out_len] = '\0';
    return result;
}

// base64_decode: decode base64 String. Returns NULL for invalid input.
static int blorp_b64_decode_char(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static blorp_String* blorp_base64_decode_result(const blorp_String* s) {
    if (!s || s->len == 0) {
        return __blorp_empty_str;
    }
    // Skip trailing whitespace and validate length
    long input_len = s->len;
    while (input_len > 0 && (s->data[input_len - 1] == '\n' || s->data[input_len - 1] == '\r' ||
           s->data[input_len - 1] == ' ' || s->data[input_len - 1] == '\t')) {
        input_len--;
    }
    if (input_len % 4 != 0) {
        return NULL;
    }
    // Count padding
    int padding = 0;
    if (input_len >= 1 && s->data[input_len - 1] == '=') padding++;
    if (input_len >= 2 && s->data[input_len - 2] == '=') padding++;
    long out_len = (input_len / 4) * 3 - padding;
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + out_len + 1);
    result->len = out_len;
    result->capacity = out_len;
    long j = 0;
    for (long i = 0; i < input_len; i += 4) {
        int vals[4];
        for (int k = 0; k < 4; k++) {
            unsigned char c = (unsigned char)s->data[i + k];
            if (c == '=') {
                // Padding only allowed in positions 2-3 of the final group
                if (i + 4 < input_len || k < 2) {
                    blorp_release((void*)result);
                    return NULL;
                }
                vals[k] = 0;
            } else {
                vals[k] = blorp_b64_decode_char(c);
                if (vals[k] < 0) {
                    blorp_release((void*)result);
                    return NULL;
                }
            }
        }
        if (j < out_len) result->data[j++] = (char)((vals[0] << 2) | (vals[1] >> 4));
        if (j < out_len) result->data[j++] = (char)(((vals[1] & 0x0F) << 4) | (vals[2] >> 2));
        if (j < out_len) result->data[j++] = (char)(((vals[2] & 0x03) << 6) | vals[3]);
    }
    result->data[out_len] = '\0';
    return result;
}

blorp_String* blorp_base64_decode_nullable(const blorp_String* s) {
    return blorp_base64_decode_result(s);
}

blorp_String* blorp_base64_decode(const blorp_String* s) {
    return blorp_base64_decode_result(s);
}

// ============================================================================
// TCP Networking
// ============================================================================

static blorp_Result* tcp_error(const char* prefix) {
    int errnum = errno;
    char buf[256];
    snprintf(buf, sizeof(buf), "%s: %s", prefix, strerror(errnum));
    blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(buf, strlen(buf)));
    res->release_mask = 1UL;
    return res;
}

static blorp_Result* tcp_error_errno(const char* prefix, int errnum) {
    char buf[256];
    snprintf(buf, sizeof(buf), "%s: %s", prefix, strerror(errnum));
    blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(buf, strlen(buf)));
    res->release_mask = 1UL;
    return res;
}

static blorp_Result* tcp_handle_error(const char* message) {
    return blorp_result_err((void*)blorp_string_literal(message));
}

static blorp_Result* tcp_owned_ok(void* value) {
    if (!value) return tcp_handle_error("tcp: invalid handle");
    blorp_Result* res = blorp_result_ok(value);
    res->release_mask = 1UL;
    return res;
}

static bool blorp_tcp_read_size_is_valid(long max_bytes) {
    return max_bytes >= 0 && max_bytes <= BLORP_TCP_MAX_READ_BYTES;
}

static bool blorp_tcp_write_buffer_is_valid(const blorp_Bytes* data) {
    return data && data->len >= 0 && data->capacity >= 0 &&
           data->len <= data->capacity;
}

static bool blorp_tcp_host_is_numeric(const char* host, int family) {
    if (!host || host[0] == '\0') return false;

    struct in_addr addr4;
    if ((family == AF_INET || family == AF_UNSPEC) &&
        inet_pton(AF_INET, host, &addr4) == 1) {
        return true;
    }

    struct in6_addr addr6;
    if ((family == AF_INET6 || family == AF_UNSPEC) &&
        inet_pton(AF_INET6, host, &addr6) == 1) {
        return true;
    }

    return false;
}

static blorp_Result* blorp_tcp_copy_host(
    const char* op,
    blorp_String* host,
    char* host_buf,
    size_t host_buf_len
) {
    if (!host || !host_buf || host_buf_len == 0) {
        return blorp_result_err((void*)blorp_string_literal("tcp: invalid host"));
    }
    if (host->len < 0 || host->capacity < 0 || host->len > host->capacity) {
        char err_buf[128];
        snprintf(err_buf, sizeof(err_buf), "%s: invalid host", op);
        blorp_Result* err_res =
            blorp_result_err((void*)blorp_string_from_buf(err_buf, strlen(err_buf)));
        err_res->release_mask = 1UL;
        return err_res;
    }
    if ((size_t)host->len >= host_buf_len) {
        char err_buf[128];
        snprintf(err_buf, sizeof(err_buf), "%s: host too long", op);
        blorp_Result* err_res =
            blorp_result_err((void*)blorp_string_from_buf(err_buf, strlen(err_buf)));
        err_res->release_mask = 1UL;
        return err_res;
    }
    memcpy(host_buf, host->data, (size_t)host->len);
    host_buf[host->len] = '\0';
    return NULL;
}

static int blorp_tcp_getaddrinfo(
    const char* host,
    const char* port,
    struct addrinfo* hints,
    struct addrinfo** res
) {
    const char* lookup_host = host;
    if (host && host[0] == '\0' && hints && (hints->ai_flags & AI_PASSIVE)) {
        lookup_host = NULL;
    }

    struct addrinfo numeric_hints;
    if (lookup_host &&
        blorp_tcp_host_is_numeric(lookup_host, hints ? hints->ai_family : AF_UNSPEC)) {
        numeric_hints = hints ? *hints : (struct addrinfo){0};
        hints = &numeric_hints;
        hints->ai_flags |= AI_NUMERICHOST;
    }
    return getaddrinfo(lookup_host, port, hints, res);
}

static void blorp_tcp_suppress_sigpipe(int fd) {
#if defined(SO_NOSIGPIPE)
    int opt = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));
#else
    (void)fd;
#endif
}

blorp_Result* blorp_tcp_listen(blorp_String* host, long port, long backlog) {
    if (!host || port < 0 || port > 65535 || backlog < 0 || backlog > INT_MAX) {
        return blorp_result_err((void*)blorp_string_literal("tcp listen: invalid host, port, or backlog"));
    }

    char host_buf[256];
    blorp_Result* host_err =
        blorp_tcp_copy_host("tcp listen", host, host_buf, sizeof(host_buf));
    if (host_err) return host_err;

    char port_buf[8];
    snprintf(port_buf, sizeof(port_buf), "%ld", port);

    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;

    struct addrinfo* res;
    int rc = blorp_tcp_getaddrinfo(host_buf, port_buf, &hints, &res);
    if (rc != 0) {
        char err_buf[256];
        snprintf(err_buf, sizeof(err_buf), "tcp listen: getaddrinfo: %s", gai_strerror(rc));
        blorp_Result* err_res = blorp_result_err((void*)blorp_string_from_buf(err_buf, strlen(err_buf)));
        err_res->release_mask = 1UL;
        return err_res;
    }

    int fd =
        blorp_runtime_socket_cloexec(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return tcp_error("tcp listen: socket");
    }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    if (bind(fd, res->ai_addr, res->ai_addrlen) < 0) {
        freeaddrinfo(res);
        close(fd);
        return tcp_error("tcp listen: bind");
    }
    freeaddrinfo(res);

    if (listen(fd, (int)backlog) < 0) {
        close(fd);
        return tcp_error("tcp listen: listen");
    }

    if (blorp_io_reactor_set_nonblocking(fd) < 0) {
        close(fd);
        return tcp_error("tcp listen: nonblocking");
    }

    return tcp_owned_ok((void*)blorp_tcp_listener_from_open_fd(fd));
}

blorp_Result* blorp_tcp_accept(blorp_TcpListener* listener) {
    blorp_TcpInner* inner = listener ? listener->inner : NULL;
    while (true) {
        if (__blorp_cancel_current_task_if_requested()) {
            return tcp_handle_error("tcp accept: cancelled");
        }

        long server_fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &server_fd) < 0) {
            return tcp_handle_error("tcp accept: closed listener");
        }
        uint64_t generation = inner->generation;
        long timeout_ms = inner->default_timeout_ms;

        struct sockaddr_in addr;
        socklen_t addr_len = sizeof(addr);
        int client_fd = blorp_runtime_accept_cloexec(
            (int)server_fd, (struct sockaddr*)&addr, &addr_len);
        if (client_fd >= 0) {
            blorp_tcp_inner_end_op(inner);
            return tcp_owned_ok((void*)blorp_tcp_stream_from_open_fd(client_fd));
        }

        int errnum = errno;
        blorp_tcp_inner_end_op(inner);
        if (errnum == EAGAIN || errnum == EWOULDBLOCK) {
            blorp_IoWakeReason reason;
            if (blorp_tcp_inner_wait_for_reactor(
                    inner,
                    BLORP_IO_WAIT_ACCEPT,
                    BLORP_IO_INTEREST_READ,
                    (int)server_fd,
                    generation,
                    timeout_ms,
                    &reason) != 0) {
                return tcp_handle_error("tcp accept: reactor unavailable");
            }

            switch (reason) {
                case BLORP_IO_WAKE_READY:
                    continue;
                case BLORP_IO_WAKE_TIMEOUT:
                    return tcp_handle_error("tcp accept: timed out");
                case BLORP_IO_WAKE_CANCELLED:
                    (void)__blorp_cancel_current_task_if_requested();
                    return tcp_handle_error("tcp accept: cancelled");
                case BLORP_IO_WAKE_CLOSED:
                case BLORP_IO_WAKE_NONE:
                default:
                    return tcp_handle_error("tcp accept: closed listener");
            }
        }
        return tcp_error_errno("tcp accept", errnum);
    }
}

blorp_Result* blorp_tcp_connect(blorp_String* host, long port) {
    if (!host || port < 0 || port > 65535) {
        return blorp_result_err((void*)blorp_string_literal("tcp connect: invalid host or port"));
    }

    char host_buf[256];
    blorp_Result* host_err =
        blorp_tcp_copy_host("tcp connect", host, host_buf, sizeof(host_buf));
    if (host_err) return host_err;

    char port_buf[8];
    snprintf(port_buf, sizeof(port_buf), "%ld", port);

    struct addrinfo hints = {0};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* res;
    int rc = blorp_tcp_getaddrinfo(host_buf, port_buf, &hints, &res);
    if (rc != 0) {
        char err_buf[256];
        snprintf(err_buf, sizeof(err_buf), "tcp connect: getaddrinfo: %s", gai_strerror(rc));
        blorp_Result* err_res = blorp_result_err((void*)blorp_string_from_buf(err_buf, strlen(err_buf)));
        err_res->release_mask = 1UL;
        return err_res;
    }

    int fd =
        blorp_runtime_socket_cloexec(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(res);
        return tcp_error("tcp connect: socket");
    }

    if (blorp_io_reactor_set_nonblocking(fd) < 0) {
        freeaddrinfo(res);
        close(fd);
        return tcp_error("tcp connect: nonblocking");
    }

    blorp_TcpStream* stream = blorp_tcp_stream_from_open_fd(fd);
    blorp_TcpInner* inner = stream->inner;
    blorp_TcpProvisionalStreamCleanup stream_cleanup = {
        .stream = stream,
        .active = true
    };
    blorp_CancelCleanupFrame cleanup_frame;
    __blorp_task_cleanup_push_slow(
        &cleanup_frame,
        &stream_cleanup,
        &stream_cleanup,
        blorp_tcp_provisional_stream_cleanup_release);

    int connect_rc = connect(fd, res->ai_addr, res->ai_addrlen);
    int connect_err = connect_rc == 0 ? 0 : errno;
    freeaddrinfo(res);

    if (connect_rc != 0 && connect_err != EINPROGRESS) {
        blorp_Result* err = tcp_error_errno("tcp connect", connect_err);
        blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
        __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
        return err;
    }

    while (connect_rc != 0) {
        if (__blorp_cancel_current_task_if_requested()) {
            blorp_Result* err = tcp_handle_error("tcp connect: cancelled");
            blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
            __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
            return err;
        }

        long active_fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &active_fd) < 0) {
            blorp_Result* err = tcp_handle_error("tcp connect: closed stream");
            blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
            __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
            return err;
        }
        uint64_t generation = inner->generation;
        long timeout_ms = inner->default_timeout_ms;
        blorp_tcp_inner_end_op(inner);

        blorp_IoWakeReason reason;
        if (blorp_tcp_inner_wait_for_reactor(
                inner,
                BLORP_IO_WAIT_CONNECT,
                BLORP_IO_INTEREST_WRITE,
                (int)active_fd,
                generation,
                timeout_ms,
                &reason) != 0) {
            blorp_Result* err =
                tcp_handle_error("tcp connect: reactor unavailable");
            blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
            __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
            return err;
        }

        switch (reason) {
            case BLORP_IO_WAKE_READY: {
                int so_error = 0;
                socklen_t so_error_len = sizeof(so_error);
                if (getsockopt(
                        (int)active_fd,
                        SOL_SOCKET,
                        SO_ERROR,
                        &so_error,
                        &so_error_len) < 0) {
                    blorp_Result* err = tcp_error("tcp connect: so_error");
                    blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
                    __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
                    return err;
                }
                if (so_error == 0) {
                    connect_rc = 0;
                    break;
                }
                if (so_error == EINPROGRESS || so_error == EALREADY) {
                    continue;
                }
                blorp_Result* err = tcp_error_errno("tcp connect", so_error);
                blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
                __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
                return err;
            }
            case BLORP_IO_WAKE_TIMEOUT: {
                blorp_Result* err = tcp_handle_error("tcp connect: timed out");
                blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
                __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
                return err;
            }
            case BLORP_IO_WAKE_CANCELLED: {
                (void)__blorp_cancel_current_task_if_requested();
                blorp_Result* err = tcp_handle_error("tcp connect: cancelled");
                blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
                __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
                return err;
            }
            case BLORP_IO_WAKE_CLOSED:
            case BLORP_IO_WAKE_NONE:
            default: {
                blorp_Result* err = tcp_handle_error("tcp connect: closed stream");
                blorp_tcp_provisional_stream_cleanup_release(&stream_cleanup);
                __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
                return err;
            }
        }
    }

    stream_cleanup.active = false;
    __blorp_task_cleanup_pop_slot_slow(&stream_cleanup);
    return tcp_owned_ok((void*)stream);
}

blorp_Result* blorp_tcp_read(blorp_TcpStream* stream, long max_bytes) {
    blorp_TcpInner* inner = stream ? stream->inner : NULL;
    if (!blorp_tcp_read_size_is_valid(max_bytes)) {
        return tcp_handle_error("tcp read: invalid max_bytes");
    }
    if (max_bytes == 0) {
        long fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
            return tcp_handle_error("tcp read: closed stream");
        }
        blorp_tcp_inner_end_op(inner);
        blorp_Bytes* empty = blorp_bytes_new(0);
        blorp_Result* res = blorp_result_ok((void*)empty);
        res->release_mask = 1UL;
        return res;
    }

    while (true) {
        if (__blorp_cancel_current_task_if_requested()) {
            return tcp_handle_error("tcp read: cancelled");
        }

        long fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
            return tcp_handle_error("tcp read: closed stream");
        }
        uint64_t generation = inner->generation;
        long timeout_ms = inner->default_timeout_ms;

        if (blorp_io_reactor_set_nonblocking((int)fd) < 0) {
            blorp_tcp_inner_end_op(inner);
            return tcp_error("tcp read: nonblocking");
        }

        blorp_Bytes* buf = blorp_bytes_new(max_bytes);
        ssize_t n = recv((int)fd, buf->data, max_bytes, 0);
        if (n >= 0) {
            blorp_tcp_inner_end_op(inner);
            buf->len = n;
            blorp_Result* res = blorp_result_ok((void*)buf);
            res->release_mask = 1UL;
            return res;
        }

        int errnum = errno;
        blorp_tcp_inner_end_op(inner);
        blorp_release((void*)buf);

        if (errnum == EINTR) continue;
        if (errnum == EAGAIN || errnum == EWOULDBLOCK) {
            blorp_IoWakeReason reason;
            if (blorp_tcp_inner_wait_for_reactor(
                    inner,
                    BLORP_IO_WAIT_READ,
                    BLORP_IO_INTEREST_READ,
                    (int)fd,
                    generation,
                    timeout_ms,
                    &reason) != 0) {
                return tcp_handle_error("tcp read: reactor unavailable");
            }

            switch (reason) {
                case BLORP_IO_WAKE_READY:
                    continue;
                case BLORP_IO_WAKE_TIMEOUT:
                    return tcp_handle_error("tcp read: timed out");
                case BLORP_IO_WAKE_CANCELLED:
                    (void)__blorp_cancel_current_task_if_requested();
                    return tcp_handle_error("tcp read: cancelled");
                case BLORP_IO_WAKE_CLOSED:
                case BLORP_IO_WAKE_NONE:
                default:
                    return tcp_handle_error("tcp read: closed stream");
            }
        }
        return tcp_error_errno("tcp read", errnum);
    }
}

blorp_Result* blorp_tcp_write(blorp_TcpStream* stream, blorp_Bytes* data) {
    blorp_TcpInner* inner = stream ? stream->inner : NULL;
    if (!blorp_tcp_write_buffer_is_valid(data)) {
        return tcp_handle_error("tcp write: invalid data");
    }
    if (data->len == 0) {
        long fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
            return tcp_handle_error("tcp write: closed stream");
        }
        blorp_tcp_inner_end_op(inner);
        return blorp_result_ok((void*)0L);
    }

    int begin_write = blorp_tcp_inner_begin_write_op(inner);
    if (begin_write == -2) {
        return tcp_handle_error("tcp write: write already in progress");
    }
    if (begin_write != 0) {
        return tcp_handle_error("tcp write: closed stream");
    }

    blorp_TcpWriteOpCleanup write_cleanup = {
        .inner = inner,
        .active = true
    };
    blorp_CancelCleanupFrame cleanup_frame;
    __blorp_task_cleanup_push_slow(
        &cleanup_frame,
        &write_cleanup,
        &write_cleanup,
        blorp_tcp_write_op_cleanup_end);

    blorp_Result* result = NULL;
    long total = 0;
    while (total < data->len) {
        if (__blorp_cancel_current_task_if_requested()) {
            result = tcp_handle_error("tcp write: cancelled");
            goto finish;
        }

        long fd = -1;
        if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
            result = tcp_handle_error("tcp write: closed stream");
            goto finish;
        }
        uint64_t generation = inner->generation;
        long timeout_ms = inner->default_timeout_ms;

        if (blorp_io_reactor_set_nonblocking((int)fd) < 0) {
            blorp_tcp_inner_end_op(inner);
            result = tcp_error("tcp write: nonblocking");
            goto finish;
        }

        ssize_t n = send(
            (int)fd,
            data->data + total,
            data->len - total,
            BLORP_TCP_SEND_FLAGS);
        if (n > 0) {
            total += n;
            blorp_tcp_inner_end_op(inner);
            continue;
        }
        if (n == 0) {
            blorp_tcp_inner_end_op(inner);
            result = tcp_handle_error("tcp write: closed stream");
            goto finish;
        }

        int errnum = errno;
        blorp_tcp_inner_end_op(inner);
        if (errnum == EINTR) continue;
        if (errnum == EAGAIN || errnum == EWOULDBLOCK) {
            blorp_IoWakeReason reason;
            if (blorp_tcp_inner_wait_for_reactor(
                    inner,
                    BLORP_IO_WAIT_WRITE,
                    BLORP_IO_INTEREST_WRITE,
                    (int)fd,
                    generation,
                    timeout_ms,
                    &reason) != 0) {
                result = tcp_handle_error("tcp write: reactor unavailable");
                goto finish;
            }

            switch (reason) {
                case BLORP_IO_WAKE_READY:
                    continue;
                case BLORP_IO_WAKE_TIMEOUT:
                    result = tcp_handle_error("tcp write: timed out");
                    goto finish;
                case BLORP_IO_WAKE_CANCELLED:
                    (void)__blorp_cancel_current_task_if_requested();
                    result = tcp_handle_error("tcp write: cancelled");
                    goto finish;
                case BLORP_IO_WAKE_CLOSED:
                case BLORP_IO_WAKE_NONE:
                default:
                    result = tcp_handle_error("tcp write: closed stream");
                    goto finish;
            }
        }
        result = tcp_error_errno("tcp write", errnum);
        goto finish;
    }

    result = blorp_result_ok((void*)total);

finish:
    blorp_tcp_write_op_cleanup_end(&write_cleanup);
    __blorp_task_cleanup_pop_slot_slow(&write_cleanup);
    return result;
}

void blorp_tcp_close_listener(blorp_TcpListener* listener) {
    if (listener) blorp_tcp_inner_close(listener->inner);
}

void blorp_tcp_close_stream(blorp_TcpStream* stream) {
    if (stream) blorp_tcp_inner_close(stream->inner);
}

blorp_Result* blorp_tcp_set_reuse_addr(blorp_TcpListener* listener) {
    blorp_TcpInner* inner = listener ? listener->inner : NULL;
    long fd = -1;
    if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
        return tcp_handle_error("tcp set_reuse_addr: closed listener");
    }
    int opt = 1;
    if (setsockopt((int)fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        int errnum = errno;
        blorp_tcp_inner_end_op(inner);
        return tcp_error_errno("tcp set_reuse_addr", errnum);
    }
    blorp_tcp_inner_end_op(inner);
    return blorp_result_ok((void*)0L);
}

static blorp_Result* blorp_tcp_local_port_fd(long fd) {
    struct sockaddr_storage addr;
    socklen_t addr_len = sizeof(addr);
    if (getsockname((int)fd, (struct sockaddr*)&addr, &addr_len) < 0) {
        return tcp_error("tcp local_port");
    }

    switch (addr.ss_family) {
        case AF_INET:
            return blorp_result_ok(
                (void*)(long)ntohs(((struct sockaddr_in*)&addr)->sin_port));
        case AF_INET6:
            return blorp_result_ok(
                (void*)(long)ntohs(((struct sockaddr_in6*)&addr)->sin6_port));
        default:
            return blorp_result_err((void*)blorp_string_literal(
                "tcp local_port: unsupported address family"));
    }
}

blorp_Result* blorp_tcp_local_port_listener(blorp_TcpListener* listener) {
    blorp_TcpInner* inner = listener ? listener->inner : NULL;
    long fd = -1;
    if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
        return tcp_handle_error("tcp local_port: closed listener");
    }
    blorp_Result* result = blorp_tcp_local_port_fd(fd);
    blorp_tcp_inner_end_op(inner);
    return result;
}

blorp_Result* blorp_tcp_local_port_stream(blorp_TcpStream* stream) {
    blorp_TcpInner* inner = stream ? stream->inner : NULL;
    long fd = -1;
    if (blorp_tcp_inner_begin_op(inner, &fd) < 0) {
        return tcp_handle_error("tcp local_port: closed stream");
    }
    blorp_Result* result = blorp_tcp_local_port_fd(fd);
    blorp_tcp_inner_end_op(inner);
    return result;
}

static bool blorp_tcp_timeout_ms_is_valid(long ms) {
    return ms >= 0 && (uint64_t)ms <= UINT64_MAX / 1000000ULL;
}

static blorp_Result* blorp_tcp_set_timeout_inner(
    blorp_TcpInner* inner,
    long ms,
    const char* closed_message
) {
    if (!blorp_tcp_timeout_ms_is_valid(ms)) {
        return tcp_handle_error("tcp set_timeout: invalid timeout");
    }
    if (!inner) {
        return tcp_handle_error(closed_message);
    }

    pthread_mutex_lock(&inner->mutex);
    if (inner->state != BLORP_TCP_STATE_OPEN || inner->fd < 0) {
        pthread_mutex_unlock(&inner->mutex);
        return tcp_handle_error(closed_message);
    }
    inner->default_timeout_ms = ms;
    pthread_mutex_unlock(&inner->mutex);
    return blorp_result_ok((void*)0L);
}

blorp_Result* blorp_tcp_set_timeout_listener(blorp_TcpListener* listener, long ms) {
    return blorp_tcp_set_timeout_inner(
        listener ? listener->inner : NULL, ms, "tcp set_timeout: closed listener");
}

blorp_Result* blorp_tcp_set_timeout_stream(blorp_TcpStream* stream, long ms) {
    return blorp_tcp_set_timeout_inner(
        stream ? stream->inner : NULL, ms, "tcp set_timeout: closed stream");
}

// ============================================================================
// Dict (Hash Map) Operations
// ============================================================================

// Forward declaration for blorp_Tuple (defined later)
// release_mask: bit i set = elem[i] is refcounted and should be released on destruction
typedef struct { blorp_Object header; long arity; long release_mask; void* elem[]; } blorp_Tuple;
blorp_Tuple* blorp_tuple_new(long arity, ...);

// Tuple destructor: releases refcounted elements based on release_mask
void blorp_tuple_destructor(void* obj) {
    blorp_Tuple* t = (blorp_Tuple*)obj;
    for (long i = 0; i < t->arity; i++) {
        if ((t->release_mask >> i) & 1) {
            if (t->elem[i]) blorp_release(t->elem[i]);
        }
    }
}

// Set release mask on tuple and install destructor
static inline void blorp_tuple_set_rc(blorp_Tuple* t, long mask) {
    t->release_mask = mask;
    BLORP_SET_DESTRUCTOR(t, blorp_tuple_destructor);
}

// Dict: Swiss table — open addressing with group-of-16 probing
// Meta byte: 0xFF=empty, 0x80=deleted, 0x00-0x7F=occupied (h2 fingerprint)
// Occupied slots have high bit 0; empty/deleted have high bit 1.
// SIMD can compare 16 meta bytes at once to find h2 matches or empty slots.
#define DICT_META_EMPTY   0xFF
#define DICT_META_DELETED 0x80
#define DICT_GROUP_SIZE   16

typedef struct {
    blorp_Object header;
    long size;           // Number of live entries
    long order_len;      // Length of order[] including holes (-1 entries from removal)
    long capacity;       // Power of 2 (hash table capacity)
    long mask;           // capacity - 1 (for & instead of %)
    long grow_at;        // Rehash threshold (capacity * 7 / 10)
    void** keys;         // Flat array [capacity]
    void** values;       // Flat array [capacity]
    uint8_t* meta;       // [capacity]: metadata bytes
    long* order;         // Dense array of slot indices [size], preserves insertion order
    long* order_index;   // Reverse map: slot -> position in order[] (-1 if unoccupied)
    unsigned long (*hash_fn)(void*);
    bool (*eq_fn)(void*, void*);
    void (*key_release)(void*);    // ARC release for refcounted keys (NULL for primitives)
    void (*value_release)(void*);  // ARC release for refcounted values (NULL for primitives)
} blorp_Dict;

// Type-specific hash functions
// Random seed for hash functions — prevents hash collision DoS
static uint64_t __blorp_hash_seed = 0;

__attribute__((constructor))
static void __blorp_init_hash_seed(void) {
#if defined(__APPLE__)
    arc4random_buf(&__blorp_hash_seed, sizeof(__blorp_hash_seed));
#elif defined(__linux__)
    ssize_t r = getrandom(&__blorp_hash_seed, sizeof(__blorp_hash_seed), 0);
    if (r != (ssize_t)sizeof(__blorp_hash_seed)) {
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            fread(&__blorp_hash_seed, 1, sizeof(__blorp_hash_seed), f);
            fclose(f);
        }
    }
#else
    FILE* f = fopen("/dev/urandom", "rb");
    if (f) {
        fread(&__blorp_hash_seed, 1, sizeof(__blorp_hash_seed), f);
        fclose(f);
    }
#endif
}

static inline unsigned long blorp_dict_hash_int(void* key) {
    unsigned long val = (unsigned long)(intptr_t)key;
    val ^= __blorp_hash_seed;
    val = (val ^ (val >> 30)) * 0xbf58476d1ce4e5b9UL;
    val = (val ^ (val >> 27)) * 0x94d049bb133111ebUL;
    return val ^ (val >> 31);
}

// wyhash core: fast non-cryptographic hash (processes 8 bytes/iteration)
static inline uint64_t __wyhash_read8(const uint8_t* p) {
    uint64_t v; memcpy(&v, p, 8); return v;
}
static inline uint64_t __wyhash_read4(const uint8_t* p) {
    uint32_t v; memcpy(&v, p, 4); return v;
}
static inline uint64_t __wyhash_mum(uint64_t a, uint64_t b) {
    __uint128_t r = (__uint128_t)a * b;
    return (uint64_t)(r >> 64) ^ (uint64_t)r;
}
static inline uint64_t __wyhash_mix(uint64_t a, uint64_t b) {
    return __wyhash_mum(a ^ 0x53c5ca59e6b02c97ULL, b ^ 0x6c62272e07bb0142ULL);
}

static unsigned long blorp_dict_hash_string(void* key) {
    blorp_String* str = (blorp_String*)key;
    if (!str || str->len == 0) return __blorp_hash_seed;
    const uint8_t* p = (const uint8_t*)str->data;
    long len = str->len;
    uint64_t seed = __blorp_hash_seed;
    uint64_t a, b;
    if (len <= 16) {
        if (len >= 4) {
            a = (__wyhash_read4(p) << 32) | __wyhash_read4(p + ((len >> 3) << 2));
            b = (__wyhash_read4(p + len - 4) << 32) | __wyhash_read4(p + len - 4 - ((len >> 3) << 2));
        } else if (len > 0) {
            a = ((uint64_t)p[0] << 16) | ((uint64_t)p[len >> 1] << 8) | p[len - 1];
            b = 0;
        } else {
            a = b = 0;
        }
    } else {
        long i = len;
        if (i > 48) {
            uint64_t s1 = seed, s2 = seed;
            do {
                seed = __wyhash_mix(__wyhash_read8(p) ^ 0x2d358dccaa6c78a5ULL, __wyhash_read8(p + 8) ^ seed);
                s1 = __wyhash_mix(__wyhash_read8(p + 16) ^ 0xa0761d6478bd642fULL, __wyhash_read8(p + 24) ^ s1);
                s2 = __wyhash_mix(__wyhash_read8(p + 32) ^ 0xe7037ed1a0b428dbULL, __wyhash_read8(p + 40) ^ s2);
                p += 48; i -= 48;
            } while (i > 48);
            seed ^= s1 ^ s2;
        }
        while (i > 16) {
            seed = __wyhash_mix(__wyhash_read8(p) ^ 0x2d358dccaa6c78a5ULL, __wyhash_read8(p + 8) ^ seed);
            i -= 16; p += 16;
        }
        a = __wyhash_read8(p + i - 16);
        b = __wyhash_read8(p + i - 8);
    }
    return (unsigned long)__wyhash_mix(0x2d358dccaa6c78a5ULL ^ (uint64_t)len, __wyhash_mum(a ^ 0x2d358dccaa6c78a5ULL, b ^ seed));
}

static bool blorp_dict_key_eq_int(void* a, void* b) {
    return a == b;
}

static bool blorp_dict_key_eq_string(void* a, void* b) {
    return blorp_string_eq((blorp_String*)a, (blorp_String*)b);
}

static unsigned long blorp_dict_hash_float(void* key) {
    union { void* p; double d; } u;
    u.p = key;
    double d = u.d;
    if (d == 0.0) d = 0.0;
    union { double dd; unsigned long ul; } bits;
    bits.dd = d;
    unsigned long val = bits.ul ^ __blorp_hash_seed;
    val = (val ^ (val >> 30)) * 0xbf58476d1ce4e5b9UL;
    val = (val ^ (val >> 27)) * 0x94d049bb133111ebUL;
    return val ^ (val >> 31);
}

static bool blorp_dict_key_eq_float(void* a, void* b) {
    union { void* p; double d; } ua, ub;
    ua.p = a;
    ub.p = b;
    return ua.d == ub.d;
}

// ---------------------------------------------------------------------------
// Hashable trait wrappers
// ---------------------------------------------------------------------------
// Typed wrappers around the dict-internal hashers, callable from generated
// blorp code via the `hash()` trait method. The wrappers match blorp's
// C calling convention (typed args, `long` return) so [Core_specialize]
// can emit a direct function call without casting. The underlying hash is
// seeded wyhash / SplitMix on primitive bit-patterns — HashDoS-resistant
// but NOT cryptographic. For SHA-256 and friends see std/hash.brp.
long blorp_hash_int(long k) {
    return (long)blorp_dict_hash_int((void*)(intptr_t)k);
}

long blorp_hash_string(blorp_String* s) {
    return (long)blorp_dict_hash_string((void*)s);
}

long blorp_hash_float(double d) {
    union { double dd; void* p; } u;
    u.dd = d;
    return (long)blorp_dict_hash_float(u.p);
}

// Binary hash mixer for multi-field Hashable impls. The mixing
// constants come from the boost::hash_combine pattern (the golden-
// ratio magic number) extended with SplitMix finalizers matching
// [blorp_dict_hash_int] for consistency. Non-commutative: the
// user's field-order choice is preserved in the chain, so two
// records that differ only in field values at different positions
// hash differently.
long blorp_hash_combine(long seed, long value) {
    unsigned long s = (unsigned long)seed;
    unsigned long v = (unsigned long)value;
    unsigned long h = s ^ (v + 0x9e3779b97f4a7c15UL + (s << 12) + (s >> 4));
    h = (h ^ (h >> 30)) * 0xbf58476d1ce4e5b9UL;
    h = (h ^ (h >> 27)) * 0x94d049bb133111ebUL;
    return (long)(h ^ (h >> 31));
}

// Compute h2 fingerprint: low 7 bits from top of hash (0x00-0x7F, high bit always 0)
static inline uint8_t blorp_dict_h2(unsigned long hash) {
    return (uint8_t)(hash >> 57) & 0x7F;
}

// Find slot for key via linear probing with Swiss-table-style h2 fingerprints.
// Meta encoding: 0xFF=empty, 0x80=deleted, 0x00-0x7F=h2 (occupied).
// Returns slot index if found, -1 if not found.
// If out_insert_slot is non-NULL and key not found, writes the first available slot.
static long blorp_dict_find_slot(blorp_Dict* dict, void* key, unsigned long hash, long* out_insert_slot) {
    uint8_t h2 = blorp_dict_h2(hash);
    long i = (long)(hash & (unsigned long)dict->mask);
    long first_available = -1;
    long probes = 0;
    while (probes <= dict->capacity) {
        uint8_t m = dict->meta[i];
        if (m == h2 && dict->eq_fn(dict->keys[i], key)) {
            return i;  // Found
        }
        if (m == DICT_META_EMPTY) {
            // Empty slot: key is definitely absent
            if (out_insert_slot) {
                *out_insert_slot = (first_available >= 0) ? first_available : i;
            }
            return -1;
        }
        if (m == DICT_META_DELETED && first_available == -1) {
            first_available = i;
        }
        i = (i + 1) & dict->mask;
        probes++;
    }
    if (out_insert_slot && first_available >= 0) {
        *out_insert_slot = first_available;
    }
    return -1;
}

// Allocate dict arrays for a given capacity
static void blorp_dict_alloc_arrays(blorp_Dict* dict, long capacity) {
    dict->capacity = capacity;
    dict->mask = capacity - 1;
    dict->grow_at = capacity * 7 / 10;
    dict->keys = (void**)blorp_calloc_checked(capacity, sizeof(void*));
    dict->values = (void**)blorp_calloc_checked(capacity, sizeof(void*));
    dict->meta = (uint8_t*)blorp_simd_alloc(capacity);
    memset(dict->meta, DICT_META_EMPTY, capacity);
    dict->order = (long*)blorp_malloc_checked(blorp_checked_mul(capacity, sizeof(long)));
    dict->order_index = (long*)blorp_malloc_checked(blorp_checked_mul(capacity, sizeof(long)));
    memset(dict->order_index, 0xFF, capacity * sizeof(long));
}

static long blorp_hash_capacity_at_least(long min_cap) {
    if (min_cap <= 16) return 16;
    const unsigned long max_cap = ((unsigned long)LONG_MAX >> 1) + 1UL;
    unsigned long target = (unsigned long)min_cap;
    unsigned long cap = 16;
    while (cap < target) {
        if (cap >= max_cap) return (long)max_cap;
        cap <<= 1;
    }
    return (long)cap;
}

static long blorp_dict_capacity_for_len(long len) {
    if (len <= 0) return 16;
    const unsigned long max_long = (unsigned long)LONG_MAX;
    unsigned long target_len = (unsigned long)len;
    if (target_len > max_long / 10UL) {
        return blorp_hash_capacity_at_least(LONG_MAX);
    }
    unsigned long min_cap = (target_len * 10UL + 6UL) / 7UL;
    if (min_cap > max_long) return blorp_hash_capacity_at_least(LONG_MAX);
    return blorp_hash_capacity_at_least((long)min_cap);
}

static void blorp_dict_destroy(void* obj) {
    blorp_Dict* dict = (blorp_Dict*)obj;
    for (long i = 0; i < dict->order_len; i++) {
        long slot = dict->order[i];
        if (slot < 0) continue;
        if (dict->key_release && dict->keys[slot]) dict->key_release(dict->keys[slot]);
        if (dict->value_release && dict->values[slot]) dict->value_release(dict->values[slot]);
    }
    free(dict->keys);
    free(dict->values);
    free(dict->meta);
    free(dict->order);
    free(dict->order_index);
}

blorp_Dict* blorp_dict_new(void) {
    long initial_capacity = 16;
    blorp_Dict* dict = (blorp_Dict*)blorp_alloc(sizeof(blorp_Dict));
    dict->size = 0;
    dict->order_len = 0;
    blorp_dict_alloc_arrays(dict, initial_capacity);
    dict->hash_fn = blorp_dict_hash_int;
    dict->eq_fn = blorp_dict_key_eq_int;
    dict->key_release = NULL;
    dict->value_release = NULL;
    BLORP_SET_DESTRUCTOR(dict, blorp_dict_destroy);
    return dict;
}

blorp_Dict* blorp_dict_new_string(void) {
    blorp_Dict* dict = blorp_dict_new();
    dict->hash_fn = blorp_dict_hash_string;
    dict->eq_fn = blorp_dict_key_eq_string;
    dict->key_release = blorp_elem_release_fn;
    return dict;
}

blorp_Dict* blorp_dict_new_float(void) {
    blorp_Dict* dict = blorp_dict_new();
    dict->hash_fn = blorp_dict_hash_float;
    dict->eq_fn = blorp_dict_key_eq_float;
    return dict;
}

void blorp_dict_init_key_string(blorp_Dict* dict) {
    if (!dict || dict->hash_fn == blorp_dict_hash_string) return;
    dict->hash_fn = blorp_dict_hash_string;
    dict->eq_fn = blorp_dict_key_eq_string;
    dict->key_release = blorp_elem_release_fn;
}

// ---------------------------------------------------------------------------
// Custom (user-defined Hashable+Equatable) key dispatch
// ---------------------------------------------------------------------------
// Takes caller-supplied hash_fn and eq_fn for keys whose types live outside
// the primitive set. The codegen for [Dict[UserType, V]] (where UserType
// has source-level Hashable + Equatable impls) routes construction through
// this entry point, passing the user impl functions with ABI-compatible
// pointer casts. key_release is NULL for value-type keys (structs held by
// value boxed into void*) and the standard ARC release otherwise.
//
// The cast of the user's [Hashable_hash_T(T*) -> long] to
// [unsigned long (*)(void*)] is technically UB under strict C, but every
// platform blorp targets (x86_64 / aarch64 macOS, Linux, BSD) has
// ABI-compatible layouts for pointer-arg + word-return. If CFI is ever
// enabled, this call site needs per-type shims instead.
blorp_Dict* blorp_dict_new_custom(
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*key_release)(void*)
) {
    blorp_Dict* dict = blorp_dict_new();
    dict->hash_fn = hash_fn;
    dict->eq_fn = eq_fn;
    dict->key_release = key_release;
    return dict;
}

void blorp_dict_init_key_float(blorp_Dict* dict) {
    if (!dict || dict->hash_fn == blorp_dict_hash_float) return;
    dict->hash_fn = blorp_dict_hash_float;
    dict->eq_fn = blorp_dict_key_eq_float;
}

void blorp_dict_set_value_release(blorp_Dict* dict, void (*release_fn)(void*)) {
    if (!dict || dict->value_release == release_fn) return;
    if (!dict->value_release && release_fn) {
        for (long i = 0; i < dict->order_len; i++) {
            long slot = dict->order[i];
            if (slot < 0) continue;
            if (dict->values[slot]) blorp_retain(dict->values[slot]);
        }
    }
    dict->value_release = release_fn;
}

blorp_Option* blorp_dict_get(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_option_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        void* val = dict->values[slot];
        if (dict->value_release && val) blorp_retain(val);
        blorp_Option* opt = blorp_option_some(val);
        if (dict->value_release) opt->release_mask = 1UL;
        return opt;
    }
    return blorp_option_none();
}

bool blorp_dict_get_raw(blorp_Dict* dict, void* key, void** out_value) {
    if (__builtin_expect(!dict, 0)) return false;
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        if (out_value) *out_value = dict->values[slot];
        return true;
    }
    return false;
}

void* blorp_dict_get_nullable(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return NULL;
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        void* val = dict->values[slot];
        if (dict->value_release && val) blorp_retain(val);
        return val;
    }
    return NULL;
}

blorp_StackOption_Int blorp_dict_get_int(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_int_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_int_some((long)dict->values[slot]);
    }
    return blorp_stack_option_int_none();
}

#define BLORP_DEFINE_DICT_GET_SIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_dict_get_##SUFFIX(blorp_Dict* dict, void* key) { \
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_##SUFFIX##_none(); \
    unsigned long hash = dict->hash_fn(key); \
    long slot = blorp_dict_find_slot(dict, key, hash, NULL); \
    if (slot >= 0) { \
        return blorp_stack_option_##SUFFIX##_some((CTYPE)(intptr_t)dict->values[slot]); \
    } \
    return blorp_stack_option_##SUFFIX##_none(); \
}

#define BLORP_DEFINE_DICT_GET_UNSIGNED(SUFFIX, NAME, CTYPE) \
blorp_StackOption_##NAME blorp_dict_get_##SUFFIX(blorp_Dict* dict, void* key) { \
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_##SUFFIX##_none(); \
    unsigned long hash = dict->hash_fn(key); \
    long slot = blorp_dict_find_slot(dict, key, hash, NULL); \
    if (slot >= 0) { \
        return blorp_stack_option_##SUFFIX##_some((CTYPE)(uintptr_t)dict->values[slot]); \
    } \
    return blorp_stack_option_##SUFFIX##_none(); \
}

BLORP_DEFINE_DICT_GET_SIGNED(int8, Int8, int8_t)
BLORP_DEFINE_DICT_GET_SIGNED(int16, Int16, int16_t)
BLORP_DEFINE_DICT_GET_SIGNED(int32, Int32, int32_t)
BLORP_DEFINE_DICT_GET_SIGNED(int64, Int64, long)
BLORP_DEFINE_DICT_GET_UNSIGNED(uint8, UInt8, uint8_t)
BLORP_DEFINE_DICT_GET_UNSIGNED(uint16, UInt16, uint16_t)
BLORP_DEFINE_DICT_GET_UNSIGNED(uint32, UInt32, uint32_t)
BLORP_DEFINE_DICT_GET_UNSIGNED(uint64, UInt64, uint64_t)

#undef BLORP_DEFINE_DICT_GET_SIGNED
#undef BLORP_DEFINE_DICT_GET_UNSIGNED

blorp_StackOption_Float blorp_dict_get_float(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_float_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_float_some(blorp_unbox_float(dict->values[slot]));
    }
    return blorp_stack_option_float_none();
}

blorp_StackOption_Bool blorp_dict_get_bool(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_bool_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_bool_some((long)dict->values[slot]);
    }
    return blorp_stack_option_bool_none();
}

blorp_StackOption_Char blorp_dict_get_char(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_char_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_char_some((int32_t)(long)dict->values[slot]);
    }
    return blorp_stack_option_char_none();
}

blorp_StackOption_Float32 blorp_dict_get_f32(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_float32_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_float32_some(blorp_unbox_float32(dict->values[slot]));
    }
    return blorp_stack_option_float32_none();
}

#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_dict_get_f16(blorp_Dict* dict, void* key) {
    if (__builtin_expect(!dict, 0)) return blorp_stack_option_float16_none();
    unsigned long hash = dict->hash_fn(key);
    long slot = blorp_dict_find_slot(dict, key, hash, NULL);
    if (slot >= 0) {
        return blorp_stack_option_float16_some(blorp_unbox_float16(dict->values[slot]));
    }
    return blorp_stack_option_float16_none();
}
#endif

// (blorp_dict_lookup removed — unused)

static blorp_Dict* blorp_dict_copy(blorp_Dict* src) {
    if (!src) return blorp_dict_new();
    blorp_Dict* dict = (blorp_Dict*)blorp_alloc(sizeof(blorp_Dict));
    dict->size = src->size;
    dict->order_len = src->order_len;
    blorp_dict_alloc_arrays(dict, src->capacity);
    dict->hash_fn = src->hash_fn;
    dict->eq_fn = src->eq_fn;
    dict->key_release = src->key_release;
    dict->value_release = src->value_release;
    BLORP_SET_DESTRUCTOR(dict, blorp_dict_destroy);
    // Bulk copy all arrays
    memcpy(dict->keys, src->keys, src->capacity * sizeof(void*));
    memcpy(dict->values, src->values, src->capacity * sizeof(void*));
    memcpy(dict->meta, src->meta, src->capacity);
    memcpy(dict->order, src->order, src->order_len * sizeof(long));
    memcpy(dict->order_index, src->order_index, src->capacity * sizeof(long));
    // Retain all occupied keys and values
    for (long i = 0; i < dict->order_len; i++) {
        long slot = dict->order[i];
        if (slot < 0) continue;
        if (dict->key_release && dict->keys[slot]) blorp_retain(dict->keys[slot]);
        if (dict->value_release && dict->values[slot]) blorp_retain(dict->values[slot]);
    }
    return dict;
}

// Rehash into larger table (no tombstones in result)
static void blorp_dict_rehash(blorp_Dict* dict, long new_capacity) {
    void** old_keys = dict->keys;
    void** old_values = dict->values;
    uint8_t* old_meta = dict->meta;
    long* old_order = dict->order;
    long* old_order_index = dict->order_index;
    long old_order_len = dict->order_len;

    blorp_dict_alloc_arrays(dict, new_capacity);
    dict->size = 0;
    dict->order_len = 0;

    // Re-insert entries in insertion order (compacts holes and tombstones)
    for (long i = 0; i < old_order_len; i++) {
        long old_slot = old_order[i];
        if (old_slot < 0) continue;
        void* key = old_keys[old_slot];
        void* value = old_values[old_slot];
        unsigned long hash = dict->hash_fn(key);
        long insert_slot = -1;
        blorp_dict_find_slot(dict, key, hash, &insert_slot);
        dict->meta[insert_slot] = blorp_dict_h2(hash);
        dict->keys[insert_slot] = key;
        dict->values[insert_slot] = value;
        dict->order_index[insert_slot] = dict->order_len;
        dict->order[dict->order_len++] = insert_slot;
        dict->size++;
    }

    free(old_keys);
    free(old_values);
    free(old_meta);
    free(old_order);
    free(old_order_index);
}

blorp_Dict* blorp_dict_insert(blorp_Dict* dict, void* key, void* value) {
    bool was_shared = __builtin_expect(!blorp_is_unique(dict), 0);
    blorp_Dict* result = was_shared ? blorp_dict_copy(dict) : dict;
    if (was_shared) blorp_release(dict);

    unsigned long hash = result->hash_fn(key);
    long insert_slot = -1;
    long found = blorp_dict_find_slot(result, key, hash, &insert_slot);

    if (found >= 0) {
        // Key exists — update value
        void* old_value = result->values[found];
        if (old_value != value) {
            if (result->value_release && old_value) result->value_release(old_value);
            result->values[found] = value;
            if (result->value_release && value) blorp_retain(value);
        }
        return result;
    }

    // Insert new entry
    result->meta[insert_slot] = blorp_dict_h2(hash);
    result->keys[insert_slot] = key;
    result->values[insert_slot] = value;
    if (result->key_release && key) blorp_retain(key);
    if (result->value_release && value) blorp_retain(value);
    result->order_index[insert_slot] = result->order_len;
    result->order[result->order_len++] = insert_slot;
    result->size++;

    // Grow if load factor exceeds 70%
    if (__builtin_expect(result->size >= result->grow_at, 0)) {
        blorp_dict_rehash(result, result->capacity * 2);
    }

    return result;
}

blorp_Dict* blorp_dict_remove(blorp_Dict* dict, void* key) {
    if (!dict) return blorp_dict_new();

    bool was_shared = !blorp_is_unique(dict);
    blorp_Dict* result = was_shared ? blorp_dict_copy(dict) : dict;
    if (was_shared) blorp_release(dict);

    unsigned long hash = result->hash_fn(key);
    long slot = blorp_dict_find_slot(result, key, hash, NULL);

    if (slot >= 0) {
        // Release key and value
        if (result->key_release && result->keys[slot]) result->key_release(result->keys[slot]);
        if (result->value_release && result->values[slot]) result->value_release(result->values[slot]);
        result->meta[slot] = DICT_META_DELETED;
        result->keys[slot] = NULL;
        result->values[slot] = NULL;
        // O(1) removal: mark slot as hole in order array, skip during iteration.
        // The order array preserves insertion order — holes are compacted on rehash.
        result->order[result->order_index[slot]] = -1;
        result->order_index[slot] = -1;
        result->size--;
    }

    return result;
}

// Dict contains, get_or, keys, values, entries, and length are now IR intrinsics.

blorp_List* blorp_dict_entries(blorp_Dict* dict) {
    blorp_List* result = blorp_list_new(dict ? dict->size : 0);
    result->elem_release = blorp_elem_release_fn;
    if (!dict) return result;
    long rc_mask = 0;
    if (dict->key_release) rc_mask |= 1;
    if (dict->value_release) rc_mask |= 2;
    long j = 0;
    for (long i = 0; i < dict->order_len; i++) {
        long slot = dict->order[i];
        if (slot < 0) continue;
        void* key = dict->keys[slot];
        void* value = dict->values[slot];
        if (dict->key_release && key) blorp_retain(key);
        if (dict->value_release && value) blorp_retain(value);
        blorp_Tuple* tuple = blorp_tuple_new(2, key, value);
        if (rc_mask) blorp_tuple_set_rc(tuple, rc_mask);
        blorp_list_set_raw(result, j++, (void*)tuple);
    }
    result->len = dict->size;
    return result;
}

// ============================================================================
// Set (Hash Set) Operations
// ============================================================================

typedef struct blorp_SetEntry {
    void* key;
    struct blorp_SetEntry* next;        // bucket chain
    struct blorp_SetEntry* prev_order;  // insertion order
    struct blorp_SetEntry* next_order;  // insertion order
} blorp_SetEntry;

typedef struct {
    blorp_Object header;
    long size;
    long capacity;
    long mask;           // capacity - 1 (for & instead of %)
    blorp_SetEntry** buckets;
    blorp_SetEntry* first;  // oldest entry (insertion order)
    blorp_SetEntry* last;   // newest entry (insertion order)
    unsigned long (*hash_fn)(void*);
    bool (*eq_fn)(void*, void*);
    void (*key_release)(void*);  // ARC release for refcounted keys (NULL for primitives)
} blorp_Set;

static void blorp_set_destroy(void* obj) {
    blorp_Set* set = (blorp_Set*)obj;
    blorp_SetEntry* entry = set->first;
    while (entry) {
        blorp_SetEntry* next = entry->next_order;
        if (set->key_release && entry->key) set->key_release(entry->key);
        free(entry);
        entry = next;
    }
    free(set->buckets);
}

static long blorp_set_capacity_for_len(long len) {
    if (len <= 0) return 16;
    const unsigned long max_cap = ((unsigned long)LONG_MAX >> 1) + 1UL;
    unsigned long ulen = (unsigned long)len;
    if (ulen > (max_cap * 3UL) / 4UL) return (long)max_cap;
    unsigned long needed = (ulen * 4UL + 2UL) / 3UL;
    unsigned long cap = 16;
    while (cap < needed) {
        if (cap >= max_cap) return (long)max_cap;
        cap <<= 1;
    }
    return (long)cap;
}

blorp_Set* blorp_set_new(void) {
    long initial_capacity = 16;
    blorp_Set* set = (blorp_Set*)blorp_alloc(sizeof(blorp_Set));
    set->size = 0;
    set->capacity = initial_capacity;
    set->mask = initial_capacity - 1;
    set->buckets = (blorp_SetEntry**)blorp_calloc_checked(initial_capacity, sizeof(blorp_SetEntry*));
    set->first = NULL;
    set->last = NULL;
    set->hash_fn = blorp_dict_hash_int;
    set->eq_fn = blorp_dict_key_eq_int;
    set->key_release = NULL;
    BLORP_SET_DESTRUCTOR(set, blorp_set_destroy);
    return set;
}

blorp_Set* blorp_set_new_string(void) {
    blorp_Set* set = blorp_set_new();
    set->hash_fn = blorp_dict_hash_string;
    set->eq_fn = blorp_dict_key_eq_string;
    set->key_release = blorp_elem_release_fn;  // String keys are refcounted
    return set;
}

blorp_Set* blorp_set_new_float(void) {
    blorp_Set* set = blorp_set_new();
    set->hash_fn = blorp_dict_hash_float;
    set->eq_fn = blorp_dict_key_eq_float;
    return set;
}

// Custom Set constructor for user types with source-level Hashable +
// Equatable impls. See [blorp_dict_new_custom] for the ABI rationale.
blorp_Set* blorp_set_new_custom(
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*elem_release)(void*)
) {
    blorp_Set* set = blorp_set_new();
    set->hash_fn = hash_fn;
    set->eq_fn = eq_fn;
    set->key_release = elem_release;
    return set;
}

static blorp_Set* blorp_set_copy(blorp_Set* src) {
    if (!src) return blorp_set_new();
    blorp_Set* set = (blorp_Set*)blorp_alloc(sizeof(blorp_Set));
    set->size = src->size;
    set->capacity = src->capacity;
    set->mask = src->mask;
    set->buckets = (blorp_SetEntry**)blorp_calloc_checked(set->capacity, sizeof(blorp_SetEntry*));
    set->first = NULL;
    set->last = NULL;
    set->hash_fn = src->hash_fn;
    set->eq_fn = src->eq_fn;
    set->key_release = src->key_release;
    BLORP_SET_DESTRUCTOR(set, blorp_set_destroy);

    // Iterate in insertion order to preserve it in the copy
    blorp_SetEntry* src_entry = src->first;
    while (src_entry) {
        blorp_SetEntry* new_entry = (blorp_SetEntry*)blorp_malloc_checked(sizeof(blorp_SetEntry));
        new_entry->key = src_entry->key;
        // Retain key for shared ownership
        if (set->key_release && new_entry->key) blorp_retain(new_entry->key);

        // Insert into correct bucket chain
        unsigned long hash = set->hash_fn(src_entry->key);
        long bucket = hash & set->mask;
        new_entry->next = set->buckets[bucket];
        set->buckets[bucket] = new_entry;

        // Append to insertion order list
        new_entry->prev_order = set->last;
        new_entry->next_order = NULL;
        if (set->last) set->last->next_order = new_entry;
        else set->first = new_entry;
        set->last = new_entry;

        src_entry = src_entry->next_order;
    }
    return set;
}

blorp_Set* blorp_set_add(blorp_Set* set, void* key) {
    bool was_shared = !blorp_is_unique(set);
    blorp_Set* result = was_shared ? blorp_set_copy(set) : set;
    if (was_shared) blorp_release(set);
    unsigned long hash = result->hash_fn(key);
    long bucket = hash & result->mask;
    blorp_SetEntry* entry = result->buckets[bucket];
    while (entry) {
        if (result->eq_fn(entry->key, key)) return result;
        entry = entry->next;
    }
    blorp_SetEntry* new_entry = (blorp_SetEntry*)blorp_malloc_checked(sizeof(blorp_SetEntry));
    new_entry->key = key;
    // Retain key for set ownership
    if (result->key_release && key) blorp_retain(key);
    new_entry->next = result->buckets[bucket];
    result->buckets[bucket] = new_entry;

    // Append to insertion order list
    new_entry->prev_order = result->last;
    new_entry->next_order = NULL;
    if (result->last) result->last->next_order = new_entry;
    else result->first = new_entry;
    result->last = new_entry;

    result->size++;

    // Resize if load factor exceeds 0.75
    if (result->size > result->capacity * 3 / 4) {
        long new_capacity = result->capacity * 2;
        long new_mask = new_capacity - 1;
        blorp_SetEntry** new_buckets = (blorp_SetEntry**)blorp_calloc_checked(new_capacity, sizeof(blorp_SetEntry*));
        // Rehash all entries via insertion-order traversal
        blorp_SetEntry* e = result->first;
        while (e) {
            unsigned long h = result->hash_fn(e->key);
            long b = h & new_mask;
            e->next = new_buckets[b];
            new_buckets[b] = e;
            e = e->next_order;
        }
        free(result->buckets);
        result->buckets = new_buckets;
        result->capacity = new_capacity;
        result->mask = new_mask;
    }

    return result;
}

blorp_Set* blorp_set_remove(blorp_Set* set, void* key) {
    if (!set) return blorp_set_new();
    bool was_shared = !blorp_is_unique(set);
    blorp_Set* result = was_shared ? blorp_set_copy(set) : set;
    if (was_shared) blorp_release(set);
    unsigned long hash = result->hash_fn(key);
    long bucket = hash & result->mask;
    blorp_SetEntry** ptr = &result->buckets[bucket];
    while (*ptr) {
        if (result->eq_fn((*ptr)->key, key)) {
            blorp_SetEntry* to_free = *ptr;
            *ptr = (*ptr)->next;

            // Unlink from insertion order list
            if (to_free->prev_order) to_free->prev_order->next_order = to_free->next_order;
            else result->first = to_free->next_order;
            if (to_free->next_order) to_free->next_order->prev_order = to_free->prev_order;
            else result->last = to_free->prev_order;

            // Release key before freeing the entry
            if (result->key_release && to_free->key) result->key_release(to_free->key);
            free(to_free);
            result->size--;
            return result;
        }
        ptr = &(*ptr)->next;
    }
    return result;
}

static bool set_contains_internal(blorp_Set* set, void* key) {
    if (!set) return false;
    unsigned long hash = set->hash_fn(key);
    long bucket = hash & set->mask;
    blorp_SetEntry* entry = set->buckets[bucket];
    while (entry) {
        if (set->eq_fn(entry->key, key)) return true;
        entry = entry->next;
    }
    return false;
}

// Set to_list and length are now IR intrinsics.

// Internal helper for set equality; public is_subset is Blorp source.
static bool set_is_subset_internal(blorp_Set* a, blorp_Set* b) {
    if (!a || a->size == 0) return true;
    if (!b) return false;
    if (a->size > b->size) return false;  // quick reject
    blorp_SetEntry* entry = a->first;
    while (entry) {
        if (!set_contains_internal(b, entry->key)) return false;
        entry = entry->next_order;
    }
    return true;
}

// (blorp_set_combine, blorp_set_intersect, blorp_set_difference removed — now blorp source)

// (sort functions moved to blorp source — std/list.brp merge sort)

// ============================================================================
// Hash Table Intrinsic Helpers (for IR-composed set/dict operations)
// ============================================================================

// Allocate a set with given capacity (power of 2)
blorp_Set* blorp_set_alloc(long capacity) {
    if (capacity < 16) capacity = 16;
    blorp_Set* set = (blorp_Set*)blorp_alloc(sizeof(blorp_Set));
    set->size = 0;
    set->capacity = capacity;
    set->mask = capacity - 1;
    set->buckets = (blorp_SetEntry**)blorp_calloc_checked(capacity, sizeof(blorp_SetEntry*));
    set->first = NULL;
    set->last = NULL;
    set->hash_fn = blorp_dict_hash_int;
    set->eq_fn = blorp_dict_key_eq_int;
    set->key_release = NULL;
    BLORP_SET_DESTRUCTOR(set, blorp_set_destroy);
    return set;
}

// Allocate a new set entry with the given key
blorp_SetEntry* blorp_set_alloc_entry(void* key) {
    blorp_SetEntry* entry = (blorp_SetEntry*)blorp_malloc_checked(sizeof(blorp_SetEntry));
    entry->key = key;
    entry->next = NULL;
    entry->prev_order = NULL;
    entry->next_order = NULL;
    return entry;
}

// Free a set entry, releasing its key if needed
void blorp_set_free_entry(blorp_Set* set, blorp_SetEntry* entry) {
    if (set->key_release && entry->key) set->key_release(entry->key);
    free(entry);
}

// COW: return unique copy (deep copy if shared, identity if unique)
blorp_Set* blorp_set_cow(blorp_Set* set) {
    if (!set) return blorp_set_alloc(16);
    if (blorp_is_unique(set)) return set;
    blorp_Set* copy = blorp_set_copy(set);
    blorp_release(set);
    return copy;
}

blorp_Set* blorp_set_reuse_alloc(blorp_Set* set, long min_cap) {
    long new_cap = blorp_hash_capacity_at_least(min_cap);
    if (!set) return blorp_set_alloc(new_cap);

    unsigned long (*hash_fn)(void*) = set->hash_fn;
    bool (*eq_fn)(void*, void*) = set->eq_fn;
    void (*key_release)(void*) = set->key_release;

    if (!blorp_is_unique(set)) {
        blorp_release(set);
        blorp_Set* fresh = blorp_set_alloc(new_cap);
        fresh->hash_fn = hash_fn;
        fresh->eq_fn = eq_fn;
        fresh->key_release = key_release;
        return fresh;
    }

    blorp_SetEntry* entry = set->first;
    while (entry) {
        blorp_SetEntry* next = entry->next_order;
        if (key_release && entry->key) key_release(entry->key);
        free(entry);
        entry = next;
    }

    if (new_cap > set->capacity) {
        free(set->buckets);
        set->capacity = new_cap;
        set->mask = new_cap - 1;
        set->buckets =
            (blorp_SetEntry**)blorp_calloc_checked(new_cap, sizeof(blorp_SetEntry*));
    } else {
        memset(set->buckets, 0, set->capacity * sizeof(blorp_SetEntry*));
    }

    set->size = 0;
    set->first = NULL;
    set->last = NULL;
    set->hash_fn = hash_fn;
    set->eq_fn = eq_fn;
    set->key_release = key_release;
    return set;
}

// Resize set to new capacity and rehash all entries
void blorp_set_resize_to(blorp_Set* set, long new_cap) {
    free(set->buckets);
    set->capacity = new_cap;
    set->mask = new_cap - 1;
    set->buckets = (blorp_SetEntry**)blorp_calloc_checked(new_cap, sizeof(blorp_SetEntry*));
    // Re-insert all entries into new buckets
    blorp_SetEntry* entry = set->first;
    while (entry) {
        unsigned long hash = set->hash_fn(entry->key);
        long bucket = hash & set->mask;
        entry->next = set->buckets[bucket];
        set->buckets[bucket] = entry;
        entry = entry->next_order;
    }
}

void blorp_set_reserve_for_len(blorp_Set* set, long len) {
    if (!set) return;
    long new_cap = blorp_set_capacity_for_len(len);
    if (new_cap > set->capacity) {
        blorp_set_resize_to(set, new_cap);
    }
}

// Allocate a dict with given capacity (power of 2).
// Delegates to blorp_dict_alloc_arrays for SIMD-aligned meta array.
blorp_Dict* blorp_dict_alloc(long capacity) {
    capacity = blorp_hash_capacity_at_least(capacity);
    blorp_Dict* dict = (blorp_Dict*)blorp_alloc(sizeof(blorp_Dict));
    dict->size = 0;
    dict->order_len = 0;
    blorp_dict_alloc_arrays(dict, capacity);
    dict->hash_fn = blorp_dict_hash_int;
    dict->eq_fn = blorp_dict_key_eq_int;
    dict->key_release = NULL;
    dict->value_release = NULL;
    BLORP_SET_DESTRUCTOR(dict, blorp_dict_destroy);
    return dict;
}

blorp_Dict* blorp_dict_with_capacity(long expected_len) {
    return blorp_dict_alloc(blorp_dict_capacity_for_len(expected_len));
}

blorp_Dict* blorp_dict_with_capacity_string(long expected_len) {
    blorp_Dict* dict = blorp_dict_with_capacity(expected_len);
    blorp_dict_init_key_string(dict);
    return dict;
}

blorp_Dict* blorp_dict_with_capacity_float(long expected_len) {
    blorp_Dict* dict = blorp_dict_with_capacity(expected_len);
    blorp_dict_init_key_float(dict);
    return dict;
}

blorp_Dict* blorp_dict_with_capacity_custom(
    long expected_len,
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*key_release)(void*)
) {
    blorp_Dict* dict = blorp_dict_with_capacity(expected_len);
    dict->hash_fn = hash_fn;
    dict->eq_fn = eq_fn;
    dict->key_release = key_release;
    return dict;
}

// COW: return unique copy (deep copy if shared, identity if unique)
blorp_Dict* blorp_dict_cow(blorp_Dict* dict) {
    if (!dict) return blorp_dict_alloc(16);
    if (blorp_is_unique(dict)) return dict;
    blorp_Dict* copy = blorp_dict_copy(dict);
    blorp_release(dict);
    return copy;
}

blorp_Dict* blorp_dict_reuse_alloc(blorp_Dict* dict, long min_cap) {
    long new_cap = blorp_hash_capacity_at_least(min_cap);
    if (!dict) return blorp_dict_alloc(new_cap);

    unsigned long (*hash_fn)(void*) = dict->hash_fn;
    bool (*eq_fn)(void*, void*) = dict->eq_fn;
    void (*key_release)(void*) = dict->key_release;
    void (*value_release)(void*) = dict->value_release;

    if (!blorp_is_unique(dict)) {
        blorp_release(dict);
        blorp_Dict* fresh = blorp_dict_alloc(new_cap);
        fresh->hash_fn = hash_fn;
        fresh->eq_fn = eq_fn;
        fresh->key_release = key_release;
        fresh->value_release = value_release;
        return fresh;
    }

    for (long i = 0; i < dict->order_len; i++) {
        long slot = dict->order[i];
        if (slot < 0) continue;
        if (key_release && dict->keys[slot]) key_release(dict->keys[slot]);
        if (value_release && dict->values[slot]) value_release(dict->values[slot]);
    }

    if (new_cap > dict->capacity) {
        free(dict->keys);
        free(dict->values);
        free(dict->meta);
        free(dict->order);
        free(dict->order_index);
        blorp_dict_alloc_arrays(dict, new_cap);
    } else {
        memset(dict->keys, 0, dict->capacity * sizeof(void*));
        memset(dict->values, 0, dict->capacity * sizeof(void*));
        memset(dict->meta, DICT_META_EMPTY, dict->capacity);
        memset(dict->order_index, 0xFF, dict->capacity * sizeof(long));
    }

    dict->size = 0;
    dict->order_len = 0;
    dict->hash_fn = hash_fn;
    dict->eq_fn = eq_fn;
    dict->key_release = key_release;
    dict->value_release = value_release;
    return dict;
}

// Resize dict to new capacity and rehash (delegates to existing logic)
void blorp_dict_resize_to(blorp_Dict* dict, long new_cap) {
    blorp_dict_rehash(dict, new_cap);
}

// ============================================================================
// Collection Equality
// ============================================================================

// List equality helpers (non-consuming, for internal use)
static long blorp_list_eq_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_List* la = (blorp_List*)a;
    blorp_List* lb = (blorp_List*)b;
    if (la->len != lb->len) return 0;
    for (long i = 0; i < la->len; i++) {
        if (blorp_list_get(la, i) != blorp_list_get(lb, i)) return 0;
    }
    return 1;
}

static long blorp_list_eq_string_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_List* la = (blorp_List*)a;
    blorp_List* lb = (blorp_List*)b;
    if (la->len != lb->len) return 0;
    for (long i = 0; i < la->len; i++) {
        if (!blorp_string_eq((blorp_String*)blorp_list_get(la, i), (blorp_String*)blorp_list_get(lb, i))) return 0;
    }
    return 1;
}

static long blorp_list_eq_float_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_List* la = (blorp_List*)a;
    blorp_List* lb = (blorp_List*)b;
    if (la->len != lb->len) return 0;
    for (long i = 0; i < la->len; i++) {
        double da, db;
        void* ra = blorp_list_get(la, i);
        void* rb = blorp_list_get(lb, i);
        memcpy(&da, &ra, sizeof(double));
        memcpy(&db, &rb, sizeof(double));
        if (da != db) return 0;
    }
    return 1;
}

// List equality — consuming (releases both args after comparison)
long blorp_list_eq(void* a, void* b) {
    long result = blorp_list_eq_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

long blorp_list_eq_string(void* a, void* b) {
    long result = blorp_list_eq_string_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

long blorp_list_eq_float(void* a, void* b) {
    long result = blorp_list_eq_float_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

// Dict equality helpers (non-consuming) — use open addressing probing
static long blorp_dict_eq_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Dict* da = (blorp_Dict*)a;
    blorp_Dict* db = (blorp_Dict*)b;
    if (da->size != db->size) return 0;
    for (long i = 0; i < da->order_len; i++) {
        long slot_a = da->order[i];
        if (slot_a < 0) continue;
        void* key = da->keys[slot_a];
        unsigned long hash = db->hash_fn(key);
        long slot_b = blorp_dict_find_slot(db, key, hash, NULL);
        if (slot_b < 0) return 0;
        if (db->values[slot_b] != da->values[slot_a]) return 0;
    }
    return 1;
}

static long blorp_dict_eq_string_value_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Dict* da = (blorp_Dict*)a;
    blorp_Dict* db = (blorp_Dict*)b;
    if (da->size != db->size) return 0;
    for (long i = 0; i < da->order_len; i++) {
        long slot_a = da->order[i];
        if (slot_a < 0) continue;
        void* key = da->keys[slot_a];
        unsigned long hash = db->hash_fn(key);
        long slot_b = blorp_dict_find_slot(db, key, hash, NULL);
        if (slot_b < 0) return 0;
        if (!blorp_string_eq((blorp_String*)db->values[slot_b], (blorp_String*)da->values[slot_a])) return 0;
    }
    return 1;
}

static long blorp_dict_eq_float_value_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Dict* da = (blorp_Dict*)a;
    blorp_Dict* db = (blorp_Dict*)b;
    if (da->size != db->size) return 0;
    for (long i = 0; i < da->order_len; i++) {
        long slot_a = da->order[i];
        if (slot_a < 0) continue;
        void* key = da->keys[slot_a];
        unsigned long hash = db->hash_fn(key);
        long slot_b = blorp_dict_find_slot(db, key, hash, NULL);
        if (slot_b < 0) return 0;
        double da_val, db_val;
        memcpy(&da_val, &da->values[slot_a], sizeof(double));
        memcpy(&db_val, &db->values[slot_b], sizeof(double));
        if (da_val != db_val) return 0;
    }
    return 1;
}

// Dict equality — consuming
long blorp_dict_eq(void* a, void* b) {
    long result = blorp_dict_eq_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

long blorp_dict_eq_string_value(void* a, void* b) {
    long result = blorp_dict_eq_string_value_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

long blorp_dict_eq_float_value(void* a, void* b) {
    long result = blorp_dict_eq_float_value_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

// Set equality helpers (non-consuming)
static long blorp_set_eq_impl(void* a, void* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    blorp_Set* sa = (blorp_Set*)a;
    blorp_Set* sb = (blorp_Set*)b;
    if (sa->size != sb->size) return 0;
    return (long)set_is_subset_internal(sa, sb);
}

// Set equality — consuming
long blorp_set_eq(void* a, void* b) {
    long result = blorp_set_eq_impl(a, b);
    if (a) blorp_release(a);
    if (b) blorp_release(b);
    return result;
}

// ============================================================================
// Sorting and List Higher-Order Functions
// ============================================================================

// Forward declaration of blorp_Closure (defined later)
typedef struct blorp_Closure_s {
    blorp_Object header;
    void* func;
    void* env;
    long env_count;
    unsigned long env_release_mask;
} blorp_Closure;

// Helper: call a closure with one argument
static inline void* blorp_call1(blorp_Closure* closure, void* arg) {
    typedef void* (*fn1_t)(void*, void*);
    fn1_t f = (fn1_t)closure->func;
    return f(closure->env, arg);
}

// Helper: call a closure with two arguments
static inline void* blorp_call2(blorp_Closure* closure, void* arg1, void* arg2) {
    typedef void* (*fn2_t)(void*, void*, void*);
    fn2_t f = (fn2_t)closure->func;
    return f(closure->env, arg1, arg2);
}

// (sort_by functions moved to blorp source — std/list.brp merge sort)

// ============================================================================
// Thread Pool and Task System
// ============================================================================

// --- Virtual Threads: types and globals (before worker for visibility) ---

typedef struct blorp_Fiber {
    mco_coro* coro;              // minicoro coroutine
    struct blorp_Fiber* run_next;  // run queues, protected by that queue's lock
    struct blorp_Fiber* wait_next; // channel wait queues, protected by ch->mutex
    struct blorp_Fiber* pool_next; // dead fiber object cache
    struct blorp_Fiber* timer_drain_next; // transient expired-timer drain batch
    void* wake_data;             // result pointer for join wakeups
    uint64_t wake_time_ns;       // for timer queue (CLOCK_MONOTONIC)
    long timer_index;            // index in timer heap, -1 when not queued
    long owner_worker_id;        // thread-affine carrier; -1 until first resume
    int parked;                  // 1 = parked, 0 = runnable (CAS-guarded)
    int queued;                  // 1 while present in the runnable queue
    int running;                 // 1 while a worker is inside mco_resume
    int wake_pending;            // waker arrived before the running fiber yielded
} blorp_Fiber;

static _Thread_local blorp_Fiber* __blorp_current_fiber = NULL;
_Thread_local void* __blorp_current_task = NULL;  // current blorp_Task* (for cancellation checks)

typedef struct {
    blorp_Fiber* head;
    blorp_Fiber* tail;
    pthread_mutex_t lock;
    long fiber_count;
} blorp_FiberRunQueue;

typedef struct {
    blorp_FiberRunQueue* queue;
    long worker_id;  // -1 means fallback queue; any worker may drain it.
} blorp_FiberRunQueueTarget;

typedef struct {
    blorp_Fiber* head;
    blorp_Fiber* tail;
    long count;
} blorp_FiberBatchList;

typedef struct {
    blorp_Fiber* runnable_head;
    blorp_Fiber* runnable_tail;
    long runnable_count;
} blorp_TaskBatch;

typedef enum {
    BLORP_TASK_SCHEDULE_IMMEDIATE,
    BLORP_TASK_SCHEDULE_BATCH,
} blorp_TaskScheduleKind;

typedef struct {
    blorp_TaskScheduleKind kind;
    blorp_TaskBatch* batch;
} blorp_TaskScheduleTarget;

#define BLORP_TASK_BATCH_FLUSH_INTERVAL 256L

typedef struct {
    blorp_Fiber** items;         // binary min-heap by wake_time_ns
    size_t len;
    size_t cap;
    pthread_mutex_t lock;
} blorp_TimerQueue;

static blorp_FiberRunQueue __fiber_run_queue;
static blorp_TimerQueue __fiber_timer_queue;
static int __fibers_initialized = 0;
static _Atomic long __fiber_runnable_count = 0;
static _Thread_local long __blorp_current_worker_id = -1;

static pthread_mutex_t __fiber_object_pool_lock = PTHREAD_MUTEX_INITIALIZER;
static blorp_Fiber* __fiber_object_pool = NULL;
static size_t __fiber_object_pool_count = 0;

#if defined(BLORP_ASAN)
// ASan adds stack redzones around frames. Keep production fibers small, but give
// sanitizer builds enough room to exercise deep runtime paths without turning
// redzone overhead into false stack-overflow crashes.
#define BLORP_DEFAULT_FIBER_STACK_SIZE (256 * 1024)
#else
#define BLORP_DEFAULT_FIBER_STACK_SIZE (56 * 1024)
#endif
#define FIBER_ALLOC_POOL_LIMIT (128ULL * 1024ULL * 1024ULL)
#define FIBER_OBJECT_POOL_LIMIT 4096ULL
static size_t __blorp_fiber_stack_size = BLORP_DEFAULT_FIBER_STACK_SIZE;

// ============================================================================
// Fiber Stack Allocator with Guard Pages
// Uses mmap + mprotect to place an inaccessible guard page at the bottom of
// each fiber stack. Stack overflow hits the guard page, causing a deterministic
// SIGSEGV/SIGBUS instead of silent heap corruption.
// ============================================================================
#include <sys/mman.h>

static size_t __blorp_page_size = 0;

static void __blorp_init_page_size(void) {
    if (__blorp_page_size == 0) {
        __blorp_page_size = (size_t)sysconf(_SC_PAGESIZE);
    }
}

// Round up to page boundary
static inline size_t __blorp_page_align(size_t size) {
    return (size + __blorp_page_size - 1) & ~(__blorp_page_size - 1);
}

typedef struct blorp_FiberAllocBlock_s {
    struct blorp_FiberAllocBlock_s* next;
    size_t size;
} blorp_FiberAllocBlock;

static pthread_mutex_t __fiber_alloc_pool_lock = PTHREAD_MUTEX_INITIALIZER;
static blorp_FiberAllocBlock* __fiber_alloc_pool = NULL;
static size_t __fiber_alloc_pool_bytes = 0;

static size_t blorp_fiber_alloc_pool_limit(void) {
#if defined(BLORP_ASAN)
    // ASan tracks stack redzones across fiber switches; reusing custom stacks
    // can preserve poisoned stack metadata and produce false positives.
    return 0;
#else
    return FIBER_ALLOC_POOL_LIMIT;
#endif
}

static void blorp_fiber_stack_unmap(void* ptr, size_t size) {
    if (!ptr) return;
    __blorp_init_page_size();
    size_t aligned_size = __blorp_page_align(size);
    void* base = (char*)ptr - __blorp_page_size;
    munmap(base, aligned_size + __blorp_page_size);
}

static void blorp_fiber_alloc_pool_clear(void) {
    pthread_mutex_lock(&__fiber_alloc_pool_lock);
    blorp_FiberAllocBlock* block = __fiber_alloc_pool;
    __fiber_alloc_pool = NULL;
    __fiber_alloc_pool_bytes = 0;
    pthread_mutex_unlock(&__fiber_alloc_pool_lock);

    while (block) {
        blorp_FiberAllocBlock* next = block->next;
        blorp_fiber_stack_unmap(block, block->size);
        block = next;
    }
}

// Custom allocator: mmap region with guard page at the bottom
static void* blorp_fiber_stack_alloc(size_t size, void* allocator_data) {
    (void)allocator_data;
#if defined(BLORP_ASAN)
    // ASan tracks fiber stack switches itself. Use ordinary heap storage in
    // sanitizer builds so the runtime does not munmap an active ASan stack.
    void* ptr = calloc(1, size);
    if (ptr) __blorp_scheduler_stat_inc(&global_scheduler_stats.stack_allocations);
    return ptr;
#else
    __blorp_init_page_size();
    size_t pool_limit = blorp_fiber_alloc_pool_limit();
    if (pool_limit > 0) {
        pthread_mutex_lock(&__fiber_alloc_pool_lock);
        blorp_FiberAllocBlock** link = &__fiber_alloc_pool;
        while (*link) {
            blorp_FiberAllocBlock* block = *link;
            if (block->size == size) {
                *link = block->next;
                __fiber_alloc_pool_bytes -= size;
                pthread_mutex_unlock(&__fiber_alloc_pool_lock);
                __blorp_scheduler_stat_inc(&global_scheduler_stats.stack_reuses);
                return block;
            }
            link = &block->next;
        }
        pthread_mutex_unlock(&__fiber_alloc_pool_lock);
    }
    size_t aligned_size = __blorp_page_align(size);
    size_t total = aligned_size + __blorp_page_size;  // +1 page for guard
    void* ptr = mmap(NULL, total, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ptr == MAP_FAILED) return NULL;
    // Guard page at the bottom (stack grows downward)
    if (mprotect(ptr, __blorp_page_size, PROT_NONE) != 0) {
        munmap(ptr, total);
        return NULL;
    }
    // Return pointer past the guard page — minicoro uses this as stack_base
    __blorp_scheduler_stat_inc(&global_scheduler_stats.stack_allocations);
    return (char*)ptr + __blorp_page_size;
#endif
}

// Custom deallocator: unmap the full region including guard page
static void blorp_fiber_stack_dealloc(void* ptr, size_t size, void* allocator_data) {
    (void)allocator_data;
    if (!ptr) return;
#if defined(BLORP_ASAN)
    (void)size;
    free(ptr);
#else
    size_t pool_limit = blorp_fiber_alloc_pool_limit();
    if (pool_limit > 0 && size <= pool_limit) {
        pthread_mutex_lock(&__fiber_alloc_pool_lock);
        if (__fiber_alloc_pool_bytes + size <= pool_limit) {
            blorp_FiberAllocBlock* block = (blorp_FiberAllocBlock*)ptr;
            block->size = size;
            block->next = __fiber_alloc_pool;
            __fiber_alloc_pool = block;
            __fiber_alloc_pool_bytes += size;
            pthread_mutex_unlock(&__fiber_alloc_pool_lock);
            return;
        }
        pthread_mutex_unlock(&__fiber_alloc_pool_lock);
    }
    blorp_fiber_stack_unmap(ptr, size);
#endif
}

// SIGSEGV/SIGBUS handler — detect guard page faults and print helpful message
static struct sigaction __blorp_old_sigsegv;
static struct sigaction __blorp_old_sigbus;

static void __blorp_stack_overflow_handler(int sig, siginfo_t* info, void* ctx) {
    (void)ctx;
    void* fault_addr = info ? info->si_addr : NULL;
    // Provide an informative crash message with the actual signal and address.
    // Distinguish between null pointer access, suspicious addresses, and other crashes.
    char msg[384];
    const char* sig_name = sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : "SIGILL";
    const char* hint;
    if (!fault_addr || fault_addr == (void*)0) {
        hint = "  This is a null pointer dereference.\n";
    } else if ((uintptr_t)fault_addr > 0xFFFFFFFFFFFF0000ULL) {
        hint = "  The fault address looks like -1 or an invalid sentinel — likely a use-after-free or\n"
               "  uninitialized pointer. Try: ./blorp run --sanitize <file>\n";
    } else {
        hint = "  This may be a stack overflow, null pointer access, or memory corruption.\n"
               "  Try: ./blorp run --sanitize <file>\n";
    }
    int len = snprintf(msg, sizeof(msg),
        "\nblorp: fatal signal %d (%s) at address %p\n%s",
        sig, sig_name, fault_addr, hint);
    write(STDERR_FILENO, msg, len > 0 ? (size_t)len : 0);
    _exit(128 + sig);
}

static struct sigaction __blorp_old_sigill;

static void __blorp_install_stack_overflow_handler(void) {
    // Provide an alternate signal stack so the handler can run even when
    // the fiber stack is exhausted
    // SIGSTKSZ may not be a compile-time constant on newer glibc
    #ifndef BLORP_ALT_STACK_SIZE
      #define BLORP_ALT_STACK_SIZE 65536
    #endif
    static char alt_stack_buf[BLORP_ALT_STACK_SIZE];
    stack_t ss;
    ss.ss_sp = alt_stack_buf;
    ss.ss_size = BLORP_ALT_STACK_SIZE;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = __blorp_stack_overflow_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;  // SA_ONSTACK: use alternate stack
    sigaction(SIGSEGV, &sa, &__blorp_old_sigsegv);
    sigaction(SIGBUS, &sa, &__blorp_old_sigbus);
    sigaction(SIGILL, &sa, &__blorp_old_sigill);
}

// Forward declarations for fiber functions (defined after thread pool shutdown)
static void blorp_fiber_init(void);
static uint64_t blorp_timer_queue_drain(void);
static blorp_Fiber* blorp_fiber_pop(void);
static void blorp_fiber_schedule(blorp_Fiber* f);
static void blorp_fiber_enqueue_runnable(blorp_Fiber* f);
static inline int __blorp_is_cancelled(void);
static int __blorp_cancel_current_task_if_requested(void);
static void blorp_fiber_enqueue_runnable_batch(
    blorp_Fiber* head,
    blorp_Fiber* tail,
    long count
);
static void blorp_fiber_object_recycle(blorp_Fiber* f);
static void blorp_fiber_object_pool_clear(void);
static void blorp_fiber_run_queue_init(blorp_FiberRunQueue* queue);
static blorp_Fiber* blorp_fiber_run_queue_pop(
    blorp_FiberRunQueue* queue,
    long worker_id
);
static blorp_Fiber* blorp_fiber_run_queue_steal_ownerless(
    blorp_FiberRunQueue* queue,
    long worker_id
);
static blorp_Fiber* blorp_fiber_take_all_queued(blorp_FiberRunQueue* queue);
static void blorp_fiber_destroy_list(blorp_Fiber* fibers);

// --- End virtual thread forward declarations ---

// Task work item in the thread pool queue
typedef struct blorp_WorkItem_s {
    struct blorp_WorkItem_s* next;
    void (*func)(void* arg);
    void* arg;
    bool heap_allocated;
    bool release_arg_on_drop;
} blorp_WorkItem;

// Thread pool
typedef struct {
    pthread_t* threads;
    struct blorp_WorkerArg_s* worker_args;
    long num_threads;
    pthread_mutex_t queue_lock;
    pthread_cond_t queue_cond;
    pthread_cond_t* worker_conds;
    long* worker_wake_generations;
    bool* worker_waiting;
    blorp_WorkItem* queue_head;
    blorp_WorkItem* queue_tail;
    blorp_FiberRunQueue* fiber_queues;
    _Atomic long fiber_enqueue_cursor;
    _Atomic long worker_signal_cursor;
    bool shutdown;
} blorp_ThreadPool;

typedef struct blorp_WorkerArg_s {
    blorp_ThreadPool* pool;
    long worker_id;
} blorp_WorkerArg;

static blorp_ThreadPool* __blorp_pool = NULL;
static pthread_once_t __blorp_pool_once = PTHREAD_ONCE_INIT;
static long __blorp_max_threads_value = 0;  // 0 = auto-detect

static long blorp_pool_pick_worker(blorp_ThreadPool* pool) {
    if (!pool || pool->num_threads <= 0) return -1;
    long ticket =
        atomic_fetch_add_explicit(
            &pool->worker_signal_cursor, 1, memory_order_relaxed);
    long idx = ticket % pool->num_threads;
    if (idx < 0) idx += pool->num_threads;
    return idx;
}

static long blorp_pool_pick_any_worker_locked(blorp_ThreadPool* pool) {
    long start = blorp_pool_pick_worker(pool);
    if (!pool || start < 0 || !pool->worker_waiting) return start;
    for (long offset = 0; offset < pool->num_threads; offset++) {
        long idx = (start + offset) % pool->num_threads;
        if (pool->worker_waiting[idx]) return idx;
    }
    return start;
}

static void blorp_pool_signal_worker_locked(
    blorp_ThreadPool* pool,
    long worker_id
) {
    if (!pool) return;
    if (pool->worker_conds && pool->worker_wake_generations &&
        worker_id >= 0 && worker_id < pool->num_threads) {
        pool->worker_wake_generations[worker_id]++;
        pthread_cond_signal(&pool->worker_conds[worker_id]);
        return;
    }
    pthread_cond_signal(&pool->queue_cond);
}

static void blorp_pool_signal_worker(long worker_id) {
    blorp_ThreadPool* pool = __blorp_pool;
    if (!pool) return;
    pthread_mutex_lock(&pool->queue_lock);
    if (worker_id < 0) worker_id = blorp_pool_pick_any_worker_locked(pool);
    blorp_pool_signal_worker_locked(pool, worker_id);
    pthread_mutex_unlock(&pool->queue_lock);
}

static void blorp_pool_signal_any_worker(void) {
    blorp_pool_signal_worker(-1);
}

static void blorp_pool_broadcast_workers_locked(blorp_ThreadPool* pool) {
    if (!pool) return;
    if (pool->worker_conds && pool->worker_wake_generations) {
        for (long i = 0; i < pool->num_threads; i++) {
            pool->worker_wake_generations[i]++;
            pthread_cond_broadcast(&pool->worker_conds[i]);
        }
        return;
    }
    pthread_cond_broadcast(&pool->queue_cond);
}

static bool blorp_worker_has_pending_wake_locked(
    blorp_ThreadPool* pool,
    long worker_id,
    long* seen_generation
) {
    if (!pool || !seen_generation || !pool->worker_wake_generations ||
        worker_id < 0 || worker_id >= pool->num_threads) {
        return false;
    }
    long current = pool->worker_wake_generations[worker_id];
    if (current == *seen_generation) return false;
    *seen_generation = current;
    return true;
}

static void blorp_worker_note_wake_seen_locked(
    blorp_ThreadPool* pool,
    long worker_id,
    long* seen_generation
) {
    if (!pool || !seen_generation || !pool->worker_wake_generations ||
        worker_id < 0 || worker_id >= pool->num_threads) {
        return;
    }
    *seen_generation = pool->worker_wake_generations[worker_id];
}

static void blorp_worker_set_waiting_locked(
    blorp_ThreadPool* pool,
    long worker_id,
    bool waiting
) {
    if (!pool || !pool->worker_waiting ||
        worker_id < 0 || worker_id >= pool->num_threads) {
        return;
    }
    pool->worker_waiting[worker_id] = waiting;
}

// Worker thread function — hybrid fiber scheduler + work item processor
static void* __blorp_worker(void* arg) {
    blorp_WorkerArg* worker_arg = (blorp_WorkerArg*)arg;
    blorp_ThreadPool* pool = worker_arg->pool;
    long worker_id = worker_arg->worker_id;
    long worker_wake_generation_seen = 0;
    __blorp_current_worker_id = worker_id;
    // Set up per-thread alternate signal stack for fiber overflow detection
    char* alt_stack = (char*)malloc(SIGSTKSZ);
    if (alt_stack) {
        stack_t ss = { .ss_sp = alt_stack, .ss_size = SIGSTKSZ, .ss_flags = 0 };
        sigaltstack(&ss, NULL);
    }
    while (1) {
        // Phase 1: Drain expired timers into run queue
        uint64_t next_expiry = 0;
        if (__fibers_initialized) {
            next_expiry = blorp_timer_queue_drain();
            uint64_t next_io_expiry = blorp_io_deadline_queue_drain();
            if (next_io_expiry > 0 &&
                (next_expiry == 0 || next_io_expiry < next_expiry)) {
                next_expiry = next_io_expiry;
            }
        }

        // Phase 2: Try to pop a fiber from the run queue
        blorp_Fiber* fiber = NULL;
        if (__fibers_initialized) {
            if (pool->fiber_queues && worker_id >= 0 &&
                worker_id < pool->num_threads) {
                blorp_FiberRunQueue* local_queue =
                    &pool->fiber_queues[worker_id];
                __blorp_scheduler_stat_lock(
                    &local_queue->lock,
                    &global_scheduler_stats.run_queue_lock_contentions);
                fiber = blorp_fiber_run_queue_pop(local_queue, worker_id);
                pthread_mutex_unlock(&local_queue->lock);
                if (!fiber) {
                    for (long offset = 1; offset < pool->num_threads; offset++) {
                        long victim_id = (worker_id + offset) % pool->num_threads;
                        blorp_FiberRunQueue* victim_queue =
                            &pool->fiber_queues[victim_id];
                        __blorp_scheduler_stat_lock(
                            &victim_queue->lock,
                            &global_scheduler_stats.run_queue_lock_contentions);
                        fiber =
                            blorp_fiber_run_queue_steal_ownerless(
                                victim_queue, worker_id);
                        pthread_mutex_unlock(&victim_queue->lock);
                        if (fiber) {
                            __blorp_scheduler_stat_inc(
                                &global_scheduler_stats.work_steals);
                            break;
                        }
                    }
                }
            }
            if (!fiber) {
                __blorp_scheduler_stat_lock(
                    &__fiber_run_queue.lock,
                    &global_scheduler_stats.run_queue_lock_contentions);
                fiber = blorp_fiber_pop();
                pthread_mutex_unlock(&__fiber_run_queue.lock);
            }
        }

        if (fiber) {
            // (mco_status wait is in blorp_fiber_schedule)
            // Resume the fiber on this worker thread. The active task is
            // fiber-scoped, not OS-thread-scoped: a worker can run many
            // different fibers over time, and each fiber may yield at channel
            // or timer park points. Rebind the thread-local current task at
            // every resume so cooperative cancellation never reads a stale
            // task pointer left behind by a previously resumed fiber.
            void* previous_task = __blorp_current_task;
            __blorp_current_fiber = fiber;
            __blorp_current_task = mco_get_user_data(fiber->coro);
            __atomic_store_n(&fiber->running, 1, __ATOMIC_RELEASE);
            __blorp_scheduler_stat_inc(&global_scheduler_stats.fiber_resumes);
            mco_result resume_res = mco_resume(fiber->coro);
            __atomic_store_n(&fiber->running, 0, __ATOMIC_RELEASE);
            __blorp_current_task = previous_task;
            __blorp_current_fiber = NULL;
            if (resume_res == MCO_STACK_OVERFLOW) {
                fprintf(stderr,
                    "\nblorp: fiber stack overflow detected at resume\n"
                    "  Fiber stack size is fixed at %zu bytes.\n",
                    __blorp_fiber_stack_size);
                abort();
            }

            if (mco_status(fiber->coro) == MCO_DEAD) {
                // Fiber completed — clean up
                __blorp_scheduler_stat_inc(
                    &global_scheduler_stats.fibers_completed);
                mco_destroy(fiber->coro);
                blorp_fiber_object_recycle(fiber);
            } else if (__atomic_exchange_n(&fiber->wake_pending, 0, __ATOMIC_ACQ_REL)) {
                // A waker found this fiber after it had marked itself parked
                // but before it reached mco_yield. Enqueue now, from the worker
                // that observed the coroutine actually suspend, instead of
                // letting another thread race mco_resume against mco_yield.
                blorp_fiber_enqueue_runnable(fiber);
            }
            // If fiber is parked (yielded), it's been placed in a wait queue
            // by the park point code. Don't touch it.
            continue;  // Check for more fibers/work immediately
        }

        // Phase 3: No fibers — try work items (backwards compat)
        pthread_mutex_lock(&pool->queue_lock);
        if (pool->queue_head) {
            blorp_WorkItem* item = pool->queue_head;
            pool->queue_head = item->next;
            if (!pool->queue_head) pool->queue_tail = NULL;
            pthread_mutex_unlock(&pool->queue_lock);
            bool heap_allocated = item->heap_allocated;
            item->func(item->arg);
            if (heap_allocated) free(item);
            continue;
        }

        // Phase 4: Nothing to do — wait
        if (pool->shutdown) {
            pthread_mutex_unlock(&pool->queue_lock);
            if (__fibers_initialized &&
                atomic_load_explicit(
                    &__fiber_runnable_count, memory_order_acquire) > 0) {
                continue;
            }
            return NULL;
        }

        if (blorp_worker_has_pending_wake_locked(
                pool, worker_id, &worker_wake_generation_seen)) {
            pthread_mutex_unlock(&pool->queue_lock);
            continue;
        }

        if (!pool->worker_conds && __fibers_initialized &&
            atomic_load_explicit(
                &__fiber_runnable_count, memory_order_acquire) > 0) {
            pthread_mutex_unlock(&pool->queue_lock);
            continue;
        }

        // Wait for new work. Fiber wakeups target the owner worker's condvar;
        // work items and timer/deadline changes wake any worker; shutdown wakes
        // all workers. The legacy global condvar remains as a fallback before
        // per-worker condvars are initialized.
        pthread_cond_t* wait_cond =
            (pool->worker_conds && worker_id >= 0 &&
             worker_id < pool->num_threads)
                ? &pool->worker_conds[worker_id]
                : &pool->queue_cond;
        if (next_expiry > 0) {
            // Timer pending — wait until its expiry time
            struct timespec now_mono;
            clock_gettime(CLOCK_MONOTONIC, &now_mono);
            uint64_t now_ns = (uint64_t)now_mono.tv_sec * 1000000000ULL + (uint64_t)now_mono.tv_nsec;
            if (next_expiry <= now_ns) {
                // Already expired, loop immediately
                pthread_mutex_unlock(&pool->queue_lock);
                continue;
            }
            uint64_t delta_ns = next_expiry - now_ns;
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += (long)(delta_ns % 1000000000ULL);
            ts.tv_sec += (time_t)(delta_ns / 1000000000ULL);
            if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
            blorp_worker_set_waiting_locked(pool, worker_id, true);
            pthread_cond_timedwait(wait_cond, &pool->queue_lock, &ts);
            blorp_worker_set_waiting_locked(pool, worker_id, false);
            blorp_worker_note_wake_seen_locked(
                pool, worker_id, &worker_wake_generation_seen);
        } else {
            // No timers pending — wait indefinitely until signaled
            blorp_worker_set_waiting_locked(pool, worker_id, true);
            pthread_cond_wait(wait_cond, &pool->queue_lock);
            blorp_worker_set_waiting_locked(pool, worker_id, false);
            blorp_worker_note_wake_seen_locked(
                pool, worker_id, &worker_wake_generation_seen);
        }
        pthread_mutex_unlock(&pool->queue_lock);
    }
    return NULL;
}

static bool __blorp_pool_enqueue_item(
    blorp_WorkItem* item,
    void (*func)(void*),
    void* arg,
    bool heap_allocated,
    bool release_arg_on_drop
) {
    if (!__blorp_pool) return false;
    item->next = NULL;
    item->func = func;
    item->arg = arg;
    item->heap_allocated = heap_allocated;
    item->release_arg_on_drop = release_arg_on_drop;
    pthread_mutex_lock(&__blorp_pool->queue_lock);
    if (__blorp_pool->queue_tail) {
        __blorp_pool->queue_tail->next = item;
    } else {
        __blorp_pool->queue_head = item;
    }
    __blorp_pool->queue_tail = item;
    blorp_pool_signal_worker_locked(
        __blorp_pool, blorp_pool_pick_any_worker_locked(__blorp_pool));
    pthread_mutex_unlock(&__blorp_pool->queue_lock);
    return true;
}

// Submit heap-owned task work whose argument is a retained task handle that
// must be released if shutdown drains the queue before the worker can run it.
static void __blorp_pool_submit_releasing_arg(void (*func)(void*), void* arg) {
    blorp_WorkItem* item = (blorp_WorkItem*)blorp_malloc_checked(sizeof(blorp_WorkItem));
    if (!__blorp_pool_enqueue_item(item, func, arg, true, true)) {
        if (arg) blorp_release(arg);
        free(item);
    }
}

// Submit caller-owned work for a synchronous parallel operation. The caller must
// wait for the worker function to signal completion before leaving the scope.
static bool __blorp_pool_submit_scoped(
    void (*func)(void*),
    void* arg,
    blorp_WorkItem* item
) {
    return __blorp_pool_enqueue_item(item, func, arg, false, false);
}

// Forward declarations for fiber functions defined after thread pool shutdown
static void blorp_fiber_init(void);
static uint64_t blorp_timer_queue_drain(void);
static void blorp_timer_queue_insert(blorp_Fiber* f);
static void blorp_timer_queue_remove(blorp_Fiber* f);

// Initialize the thread pool
void blorp_thread_pool_init(long max_threads) {
    if (__blorp_pool) return;  // Already initialized
    // Initialize fiber infrastructure
    blorp_fiber_init();
    // CLI --threads override via environment variable
    const char* env_threads = getenv("BLORP_THREADS");
    if (env_threads) {
        long n = atol(env_threads);
        if (n > 0) max_threads = n;
    }
    if (max_threads <= 0) {
        max_threads = sysconf(_SC_NPROCESSORS_ONLN);
        if (max_threads <= 0) max_threads = 4;
    }
    __blorp_max_threads_value = max_threads;
    __blorp_pool = (blorp_ThreadPool*)blorp_malloc_checked(sizeof(blorp_ThreadPool));
    __blorp_pool->num_threads = max_threads;
    __blorp_pool->worker_args =
        (blorp_WorkerArg*)blorp_malloc_checked(max_threads * sizeof(blorp_WorkerArg));
    __blorp_pool->queue_head = NULL;
    __blorp_pool->queue_tail = NULL;
    __blorp_pool->fiber_queues =
        (blorp_FiberRunQueue*)blorp_malloc_checked(
            max_threads * sizeof(blorp_FiberRunQueue));
    __blorp_pool->worker_conds =
        (pthread_cond_t*)blorp_malloc_checked(
            max_threads * sizeof(pthread_cond_t));
    __blorp_pool->worker_wake_generations =
        (long*)blorp_malloc_checked(max_threads * sizeof(long));
    __blorp_pool->worker_waiting =
        (bool*)blorp_malloc_checked(max_threads * sizeof(bool));
    memset(
        __blorp_pool->worker_wake_generations, 0,
        max_threads * sizeof(long));
    memset(__blorp_pool->worker_waiting, 0, max_threads * sizeof(bool));
    atomic_store_explicit(
        &__blorp_pool->fiber_enqueue_cursor, 0, memory_order_relaxed);
    atomic_store_explicit(
        &__blorp_pool->worker_signal_cursor, 0, memory_order_relaxed);
    for (long i = 0; i < max_threads; i++) {
        blorp_fiber_run_queue_init(&__blorp_pool->fiber_queues[i]);
        pthread_cond_init(&__blorp_pool->worker_conds[i], NULL);
    }
    __blorp_pool->shutdown = false;
    pthread_mutex_init(&__blorp_pool->queue_lock, NULL);
    pthread_cond_init(&__blorp_pool->queue_cond, NULL);
    __blorp_pool->threads = (pthread_t*)blorp_malloc_checked(max_threads * sizeof(pthread_t));
    for (long i = 0; i < max_threads; i++) {
        __blorp_pool->worker_args[i].pool = __blorp_pool;
        __blorp_pool->worker_args[i].worker_id = i;
        pthread_create(
            &__blorp_pool->threads[i], NULL, __blorp_worker,
            &__blorp_pool->worker_args[i]);
    }
}

// Default init for pthread_once (auto-detect thread count)
static void __blorp_pool_init_default(void) {
    blorp_thread_pool_init(0);
}

// Shutdown the thread pool
void blorp_thread_pool_shutdown(void) {
    if (!__blorp_pool) return;
    pthread_mutex_lock(&__blorp_pool->queue_lock);
    __blorp_pool->shutdown = true;
    blorp_pool_broadcast_workers_locked(__blorp_pool);
    pthread_mutex_unlock(&__blorp_pool->queue_lock);
    for (long i = 0; i < __blorp_pool->num_threads; i++) {
        pthread_join(__blorp_pool->threads[i], NULL);
    }
    // Drain remaining items — release the task ref the worker would have released
    blorp_WorkItem* item = __blorp_pool->queue_head;
    while (item) {
        blorp_WorkItem* next = item->next;
        if (item->release_arg_on_drop && item->arg) blorp_release(item->arg);
        if (item->heap_allocated) free(item);
        item = next;
    }
    // Drain timer queue — free fibers that were sleeping at shutdown
    if (__fibers_initialized) {
        pthread_mutex_lock(&__fiber_timer_queue.lock);
        blorp_Fiber** timer_items = __fiber_timer_queue.items;
        size_t timer_len = __fiber_timer_queue.len;
        __fiber_timer_queue.items = NULL;
        __fiber_timer_queue.len = 0;
        __fiber_timer_queue.cap = 0;
        pthread_mutex_unlock(&__fiber_timer_queue.lock);
        for (size_t i = 0; i < timer_len; i++) {
            blorp_Fiber* tf = timer_items[i];
            if (!tf) continue;
            tf->timer_index = -1;
            if (tf->coro) { mco_destroy(tf->coro); }
            blorp_fiber_object_recycle(tf);
        }
        free(timer_items);
        blorp_io_deadline_queue_clear();
        if (__blorp_pool->fiber_queues) {
            for (long i = 0; i < __blorp_pool->num_threads; i++) {
                blorp_FiberRunQueue* queue = &__blorp_pool->fiber_queues[i];
                blorp_Fiber* queued = blorp_fiber_take_all_queued(queue);
                blorp_fiber_destroy_list(queued);
                pthread_mutex_destroy(&queue->lock);
            }
        }
        // Drain fallback run queue — normally unused after worker-local queues
        // are initialized, but kept for initialization and shutdown edges.
        blorp_Fiber* rf = blorp_fiber_take_all_queued(&__fiber_run_queue);
        blorp_fiber_destroy_list(rf);
    }
    pthread_mutex_destroy(&__blorp_pool->queue_lock);
    pthread_cond_destroy(&__blorp_pool->queue_cond);
    if (__blorp_pool->worker_conds) {
        for (long i = 0; i < __blorp_pool->num_threads; i++) {
            pthread_cond_destroy(&__blorp_pool->worker_conds[i]);
        }
    }
    free(__blorp_pool->threads);
    free(__blorp_pool->worker_args);
    free(__blorp_pool->fiber_queues);
    free(__blorp_pool->worker_conds);
    free(__blorp_pool->worker_wake_generations);
    free(__blorp_pool->worker_waiting);
    free(__blorp_pool);
    __blorp_pool = NULL;
    blorp_fiber_object_pool_clear();
    blorp_fiber_alloc_pool_clear();
}

// ============================================================================
// Virtual Threads — Function implementations
// (Types and globals are defined before the worker function above)
// ============================================================================

// Initialize fiber infrastructure (called from blorp_thread_pool_init)
static void blorp_fiber_run_queue_init(blorp_FiberRunQueue* queue) {
    queue->head = NULL;
    queue->tail = NULL;
    queue->fiber_count = 0;
    pthread_mutex_init(&queue->lock, NULL);
}

static void blorp_fiber_init(void) {
    if (__fibers_initialized) return;
    blorp_fiber_run_queue_init(&__fiber_run_queue);
    atomic_store_explicit(&__fiber_runnable_count, 0, memory_order_relaxed);
    __fiber_timer_queue.items = NULL;
    __fiber_timer_queue.len = 0;
    __fiber_timer_queue.cap = 0;
    pthread_mutex_init(&__fiber_timer_queue.lock, NULL);
    // Install guard page signal handler for fiber stack overflow detection
    __blorp_install_stack_overflow_handler();
    __fibers_initialized = 1;
}

static size_t blorp_fiber_object_pool_limit(void) {
    return FIBER_OBJECT_POOL_LIMIT;
}

static blorp_Fiber* blorp_fiber_object_alloc(void) {
    if (blorp_fiber_object_pool_limit() > 0) {
        pthread_mutex_lock(&__fiber_object_pool_lock);
        blorp_Fiber* f = __fiber_object_pool;
        if (f) {
            __fiber_object_pool = f->pool_next;
            __fiber_object_pool_count--;
            pthread_mutex_unlock(&__fiber_object_pool_lock);
            __blorp_scheduler_stat_inc(&global_scheduler_stats.fibers_reused);
            return f;
        }
        pthread_mutex_unlock(&__fiber_object_pool_lock);
    }
    __blorp_scheduler_stat_inc(&global_scheduler_stats.fibers_created);
    return (blorp_Fiber*)blorp_malloc_checked(sizeof(blorp_Fiber));
}

static void blorp_fiber_object_recycle(blorp_Fiber* f) {
    if (!f) return;
    f->run_next = NULL;
    f->wait_next = NULL;
    f->pool_next = NULL;
    f->timer_drain_next = NULL;
    size_t limit = blorp_fiber_object_pool_limit();
    if (limit > 0) {
        pthread_mutex_lock(&__fiber_object_pool_lock);
        if (__fiber_object_pool_count < limit) {
            f->pool_next = __fiber_object_pool;
            __fiber_object_pool = f;
            __fiber_object_pool_count++;
            pthread_mutex_unlock(&__fiber_object_pool_lock);
            return;
        }
        pthread_mutex_unlock(&__fiber_object_pool_lock);
    }
    free(f);
}

static void blorp_fiber_object_pool_clear(void) {
    pthread_mutex_lock(&__fiber_object_pool_lock);
    blorp_Fiber* f = __fiber_object_pool;
    __fiber_object_pool = NULL;
    __fiber_object_pool_count = 0;
    pthread_mutex_unlock(&__fiber_object_pool_lock);

    while (f) {
        blorp_Fiber* next = f->pool_next;
        free(f);
        f = next;
    }
}

// Create a new fiber wrapping a coroutine
static blorp_Fiber* blorp_fiber_create(void (*func)(mco_coro*), void* user_data) {
    blorp_Fiber* f = blorp_fiber_object_alloc();
    f->run_next = NULL;
    f->wait_next = NULL;
    f->pool_next = NULL;
    f->timer_drain_next = NULL;
    f->wake_data = NULL;
    f->wake_time_ns = 0;
    f->timer_index = -1;
    f->owner_worker_id = -1;
    f->parked = 1;  // Start as "parked" so first blorp_fiber_schedule CAS succeeds
    f->queued = 0;
    f->running = 0;
    f->wake_pending = 0;
    mco_desc desc = mco_desc_init(func, __blorp_fiber_stack_size);
    desc.user_data = user_data;
    // Use guard-page allocator for stack overflow protection
    desc.alloc_cb = blorp_fiber_stack_alloc;
    desc.dealloc_cb = blorp_fiber_stack_dealloc;
    mco_result res = mco_create(&f->coro, &desc);
    if (res != MCO_SUCCESS) {
        blorp_fiber_object_recycle(f);
        return NULL;
    }
    return f;
}

// Push a known-runnable fiber to the run queue tail, signal workers.
// Caller is responsible for transitioning parked 1 -> 0 before calling.
static long blorp_fiber_select_queue_index(blorp_ThreadPool* pool) {
    if (!pool || pool->num_threads <= 0) return -1;
    long ticket =
        atomic_fetch_add_explicit(
            &pool->fiber_enqueue_cursor, 1, memory_order_relaxed);
    long idx = ticket % pool->num_threads;
    if (idx < 0) idx += pool->num_threads;
    return idx;
}

static blorp_FiberRunQueueTarget blorp_fiber_select_run_queue(blorp_Fiber* f) {
    blorp_ThreadPool* pool = __blorp_pool;
    if (pool && pool->fiber_queues && pool->num_threads > 0) {
        long idx =
            (f && f->owner_worker_id >= 0 &&
             f->owner_worker_id < pool->num_threads)
                ? f->owner_worker_id
                : blorp_fiber_select_queue_index(pool);
        if (idx >= 0 && idx < pool->num_threads) {
            return (blorp_FiberRunQueueTarget) {
                .queue = &pool->fiber_queues[idx],
                .worker_id = idx
            };
        }
    }
    return (blorp_FiberRunQueueTarget) {
        .queue = &__fiber_run_queue,
        .worker_id = -1
    };
}

static void blorp_fiber_enqueue_runnable(blorp_Fiber* f) {
    if (f->coro && mco_status(f->coro) == MCO_DEAD) return;
    int expected = 0;
    if (!__atomic_compare_exchange_n(&f->queued, &expected, 1, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return;
    }
    f->run_next = NULL;
    blorp_FiberRunQueueTarget target = blorp_fiber_select_run_queue(f);
    blorp_FiberRunQueue* queue = target.queue;
    __blorp_scheduler_stat_lock(
        &queue->lock, &global_scheduler_stats.run_queue_lock_contentions);
    if (queue->tail) {
        queue->tail->run_next = f;
    } else {
        queue->head = f;
    }
    queue->tail = f;
    queue->fiber_count++;
    long queued_count = queue->fiber_count;
    __blorp_scheduler_stat_inc(&global_scheduler_stats.runnable_enqueues);
    atomic_fetch_add_explicit(
        &__fiber_runnable_count, 1, memory_order_release);
    pthread_mutex_unlock(&queue->lock);
    // Wake workers on a queue's empty->nonempty transition. Round-robin
    // external injection spreads large bursts across queues, so one signal per
    // newly active queue is enough to wake available carriers without creating
    // a condition-variable storm.
    if (__blorp_pool && queued_count == 1) {
        blorp_pool_signal_worker(target.worker_id);
    }
}

static void blorp_fiber_batch_list_append(blorp_FiberBatchList* list, blorp_Fiber* f) {
    f->run_next = NULL;
    if (list->tail) {
        list->tail->run_next = f;
    } else {
        list->head = f;
    }
    list->tail = f;
    list->count++;
}

static bool blorp_fiber_run_queue_append_locked(
    blorp_FiberRunQueue* queue,
    blorp_Fiber* head,
    blorp_Fiber* tail,
    long count
) {
    bool was_empty = queue->head == NULL;
    if (queue->tail) {
        queue->tail->run_next = head;
    } else {
        queue->head = head;
    }
    queue->tail = tail;
    queue->fiber_count += count;
    return was_empty;
}

#define BLORP_STACK_BATCH_QUEUES 64

static void blorp_fiber_enqueue_runnable_batch(
    blorp_Fiber* head,
    blorp_Fiber* tail,
    long count
) {
    if (!head || !tail || count <= 0) return;
    blorp_ThreadPool* pool = __blorp_pool;
    if (pool && pool->fiber_queues && pool->num_threads > 0) {
        long queue_count = pool->num_threads;
        blorp_FiberBatchList stack_batches[BLORP_STACK_BATCH_QUEUES];
        blorp_FiberBatchList* batches = stack_batches;
        size_t batches_size =
            blorp_checked_mul(queue_count, (long)sizeof(blorp_FiberBatchList));
        bool heap_batches = queue_count > BLORP_STACK_BATCH_QUEUES;
        if (heap_batches) {
            batches = (blorp_FiberBatchList*)blorp_malloc_checked(batches_size);
        }
        memset(batches, 0, batches_size);

        blorp_Fiber* f = head;
        while (f) {
            blorp_Fiber* next = f->run_next;
            long idx =
                (f->owner_worker_id >= 0 &&
                 f->owner_worker_id < pool->num_threads)
                    ? f->owner_worker_id
                    : blorp_fiber_select_queue_index(pool);
            blorp_fiber_batch_list_append(&batches[idx], f);
            f = next;
        }

        for (long i = 0; i < queue_count; i++) {
            blorp_FiberBatchList* batch = &batches[i];
            if (!batch->head) continue;
            blorp_FiberRunQueue* queue = &pool->fiber_queues[i];
            __blorp_scheduler_stat_lock(
                &queue->lock, &global_scheduler_stats.run_queue_lock_contentions);
            bool was_empty =
                blorp_fiber_run_queue_append_locked(
                    queue, batch->head, batch->tail, batch->count);
            __blorp_scheduler_stat_add(
                &global_scheduler_stats.runnable_enqueues, batch->count);
            atomic_fetch_add_explicit(
                &__fiber_runnable_count, batch->count, memory_order_release);
            pthread_mutex_unlock(&queue->lock);
            if (was_empty) blorp_pool_signal_worker(i);
        }
        if (heap_batches) free(batches);
        return;
    }

    __blorp_scheduler_stat_lock(
        &__fiber_run_queue.lock, &global_scheduler_stats.run_queue_lock_contentions);
    blorp_fiber_run_queue_append_locked(&__fiber_run_queue, head, tail, count);
    __blorp_scheduler_stat_add(&global_scheduler_stats.runnable_enqueues, count);
    atomic_fetch_add_explicit(
        &__fiber_runnable_count, count, memory_order_release);
    pthread_mutex_unlock(&__fiber_run_queue.lock);
    blorp_pool_signal_any_worker();
}

static blorp_TaskScheduleTarget blorp_task_schedule_immediate(void) {
    return (blorp_TaskScheduleTarget) {
        .kind = BLORP_TASK_SCHEDULE_IMMEDIATE,
        .batch = NULL
    };
}

static blorp_TaskScheduleTarget blorp_task_schedule_batch(blorp_TaskBatch* batch) {
    return (blorp_TaskScheduleTarget) {
        .kind = BLORP_TASK_SCHEDULE_BATCH,
        .batch = batch
    };
}

static void blorp_task_batch_add_new_fiber(blorp_TaskBatch* batch, blorp_Fiber* f) {
    // The spawning thread exclusively owns a newly created fiber until this
    // batch is published to a run queue.
    __atomic_store_n(&f->parked, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&f->queued, 1, __ATOMIC_RELEASE);
    __blorp_scheduler_stat_inc(
        &global_scheduler_stats.fiber_schedule_transitions);
    if (batch->runnable_tail) {
        batch->runnable_tail->run_next = f;
    } else {
        batch->runnable_head = f;
    }
    batch->runnable_tail = f;
    f->run_next = NULL;
    batch->runnable_count++;
}

static void blorp_task_schedule_new_fiber(
    blorp_TaskScheduleTarget schedule,
    blorp_Fiber* fiber
) {
    switch (schedule.kind) {
        case BLORP_TASK_SCHEDULE_BATCH:
            if (schedule.batch) {
                blorp_task_batch_add_new_fiber(schedule.batch, fiber);
                return;
            }
            // Defensive fallback for malformed internal callers.
            blorp_fiber_schedule(fiber);
            return;
        case BLORP_TASK_SCHEDULE_IMMEDIATE:
        default:
            blorp_fiber_schedule(fiber);
            return;
    }
}

void blorp_task_batch_init(blorp_TaskBatch* batch) {
    if (!batch) return;
    batch->runnable_head = NULL;
    batch->runnable_tail = NULL;
    batch->runnable_count = 0;
}

void blorp_task_batch_flush(blorp_TaskBatch* batch) {
    if (!batch) return;
    blorp_Fiber* head = batch->runnable_head;
    blorp_Fiber* tail = batch->runnable_tail;
    long count = batch->runnable_count;
    blorp_task_batch_init(batch);
    blorp_fiber_enqueue_runnable_batch(head, tail, count);
}

// Schedule a parked fiber.
// Idempotent: if fiber is not parked (already scheduled/running), this is a no-op.
static void blorp_fiber_schedule(blorp_Fiber* f) {
    // Atomic CAS: only the first waker transitions parked 1 -> 0
    int expected = 1;
    if (!__atomic_compare_exchange_n(&f->parked, &expected, 0, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return;  // Already scheduled by another waker
    }
    __blorp_scheduler_stat_inc(
        &global_scheduler_stats.fiber_schedule_transitions);
    // If the fiber is still inside mco_resume, it has marked itself parked
    // but has not actually yielded yet. Do not poll minicoro state from this
    // thread. Record the wake and let the running worker enqueue it after
    // mco_resume returns from the yield.
    if (__atomic_load_n(&f->running, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&f->wake_pending, 1, __ATOMIC_RELEASE);
        return;
    }
    blorp_fiber_enqueue_runnable(f);
}

static void blorp_io_waiter_wake_all(blorp_IoWaiterList* waiters) {
    if (!waiters) return;
    blorp_IoWaiter* waiter = waiters->head;
    waiters->head = NULL;
    waiters->tail = NULL;
    while (waiter) {
        blorp_IoWaiter* next = waiter->next;
        waiter->next = NULL;
        if (waiter->fiber) blorp_fiber_schedule(waiter->fiber);
        waiter = next;
    }
}

static void blorp_io_deadline_queue_init_once(void) {
    pthread_mutex_init(&__blorp_io_deadline_queue.lock, NULL);
}

static void blorp_io_deadline_queue_ensure_init(void) {
    pthread_once(
        &__blorp_io_deadline_queue_once, blorp_io_deadline_queue_init_once);
}

static uint64_t blorp_monotonic_now_ns(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}

static void blorp_io_deadline_heap_swap(size_t a, size_t b) {
    blorp_IoWaiter* tmp = __blorp_io_deadline_queue.items[a];
    __blorp_io_deadline_queue.items[a] = __blorp_io_deadline_queue.items[b];
    __blorp_io_deadline_queue.items[b] = tmp;
    __blorp_io_deadline_queue.items[a]->deadline_index = (long)a;
    __blorp_io_deadline_queue.items[b]->deadline_index = (long)b;
}

static void blorp_io_deadline_heap_sift_up(size_t idx) {
    while (idx > 0) {
        size_t parent = (idx - 1) / 2;
        if (__blorp_io_deadline_queue.items[parent]->deadline_ns <=
            __blorp_io_deadline_queue.items[idx]->deadline_ns) {
            break;
        }
        blorp_io_deadline_heap_swap(parent, idx);
        idx = parent;
    }
}

static void blorp_io_deadline_heap_sift_down(size_t idx) {
    while (true) {
        size_t left = idx * 2 + 1;
        size_t right = left + 1;
        size_t smallest = idx;
        if (left < __blorp_io_deadline_queue.len &&
            __blorp_io_deadline_queue.items[left]->deadline_ns <
                __blorp_io_deadline_queue.items[smallest]->deadline_ns) {
            smallest = left;
        }
        if (right < __blorp_io_deadline_queue.len &&
            __blorp_io_deadline_queue.items[right]->deadline_ns <
                __blorp_io_deadline_queue.items[smallest]->deadline_ns) {
            smallest = right;
        }
        if (smallest == idx) break;
        blorp_io_deadline_heap_swap(idx, smallest);
        idx = smallest;
    }
}

static void blorp_io_deadline_heap_reserve(size_t needed) {
    if (__blorp_io_deadline_queue.cap >= needed) return;
    size_t new_cap =
        __blorp_io_deadline_queue.cap ? __blorp_io_deadline_queue.cap * 2 : 64;
    while (new_cap < needed) new_cap *= 2;
    if (new_cap > SIZE_MAX / sizeof(blorp_IoWaiter*)) {
        fprintf(stderr, "blorp: IO deadline queue capacity overflow\n");
        exit(1);
    }
    blorp_IoWaiter** new_items =
        (blorp_IoWaiter**)realloc(
            __blorp_io_deadline_queue.items,
            new_cap * sizeof(blorp_IoWaiter*));
    if (!new_items) {
        fprintf(stderr, "blorp: out of memory (IO deadline queue %zu entries)\n",
                new_cap);
        exit(1);
    }
    __blorp_io_deadline_queue.items = new_items;
    __blorp_io_deadline_queue.cap = new_cap;
}

static blorp_IoDeadlineEntry blorp_io_deadline_entry_empty(void) {
    return (blorp_IoDeadlineEntry){ .waiter = NULL, .owner = NULL };
}

static void blorp_io_deadline_entry_release(blorp_IoDeadlineEntry* entry) {
    if (!entry) return;
    if (entry->owner) blorp_tcp_inner_release(entry->owner);
    if (entry->waiter) blorp_io_waiter_release(entry->waiter);
    entry->owner = NULL;
    entry->waiter = NULL;
}

static blorp_IoDeadlineEntry blorp_io_deadline_heap_remove_at_locked(size_t idx) {
    if (idx >= __blorp_io_deadline_queue.len) {
        return blorp_io_deadline_entry_empty();
    }
    blorp_IoWaiter* removed = __blorp_io_deadline_queue.items[idx];
    blorp_IoDeadlineEntry removed_entry = {
        .waiter = removed,
        .owner = removed->deadline_owner
    };
    removed->deadline_index = -1;
    removed->deadline_queued = false;
    removed->deadline_owner = NULL;
    __blorp_io_deadline_queue.len--;
    if (idx == __blorp_io_deadline_queue.len) return removed_entry;
    __blorp_io_deadline_queue.items[idx] =
        __blorp_io_deadline_queue.items[__blorp_io_deadline_queue.len];
    __blorp_io_deadline_queue.items[idx]->deadline_index = (long)idx;
    blorp_io_deadline_heap_sift_down(idx);
    blorp_io_deadline_heap_sift_up(idx);
    return removed_entry;
}

static blorp_IoDeadlineEntry blorp_io_deadline_heap_pop_min_locked(void) {
    if (__blorp_io_deadline_queue.len == 0) {
        return blorp_io_deadline_entry_empty();
    }
    return blorp_io_deadline_heap_remove_at_locked(0);
}

static void blorp_io_deadline_queue_insert(
    blorp_IoWaiter* waiter,
    blorp_TcpInner* owner
) {
    if (!waiter || waiter->deadline_ns == 0) return;
    blorp_io_deadline_queue_ensure_init();
    blorp_IoDeadlineEntry stale = blorp_io_deadline_entry_empty();
    pthread_mutex_lock(&__blorp_io_deadline_queue.lock);
    if (waiter->deadline_queued) {
        size_t idx = (size_t)waiter->deadline_index;
        if (idx < __blorp_io_deadline_queue.len &&
            __blorp_io_deadline_queue.items[idx] == waiter) {
            stale = blorp_io_deadline_heap_remove_at_locked(idx);
        } else {
            for (size_t i = 0; i < __blorp_io_deadline_queue.len; i++) {
                if (__blorp_io_deadline_queue.items[i] == waiter) {
                    stale = blorp_io_deadline_heap_remove_at_locked(i);
                    break;
                }
            }
            if (!stale.waiter) {
                pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
                fprintf(stderr, "blorp: corrupted IO deadline queue entry (bug)\n");
                abort();
            }
        }
    }
    blorp_io_deadline_heap_reserve(__blorp_io_deadline_queue.len + 1);
    size_t idx = __blorp_io_deadline_queue.len++;
    __blorp_io_deadline_queue.items[idx] = waiter;
    blorp_io_waiter_retain(waiter);
    if (owner) blorp_tcp_inner_retain(owner);
    waiter->deadline_index = (long)idx;
    waiter->deadline_queued = true;
    waiter->deadline_owner = owner;
    blorp_io_deadline_heap_sift_up(idx);
    bool changes_next_expiry = waiter->deadline_index == 0;
    pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
    blorp_io_deadline_entry_release(&stale);
    if (__blorp_pool && changes_next_expiry) blorp_pool_signal_any_worker();
}

static void blorp_io_deadline_queue_remove(blorp_IoWaiter* waiter) {
    if (!waiter) return;
    blorp_io_deadline_queue_ensure_init();
    blorp_IoDeadlineEntry removed = blorp_io_deadline_entry_empty();
    pthread_mutex_lock(&__blorp_io_deadline_queue.lock);
    if (waiter->deadline_queued) {
        size_t idx = (size_t)waiter->deadline_index;
        if (idx < __blorp_io_deadline_queue.len &&
            __blorp_io_deadline_queue.items[idx] == waiter) {
            removed = blorp_io_deadline_heap_remove_at_locked(idx);
        } else {
            for (size_t i = 0; i < __blorp_io_deadline_queue.len; i++) {
                if (__blorp_io_deadline_queue.items[i] == waiter) {
                    removed = blorp_io_deadline_heap_remove_at_locked(i);
                    break;
                }
            }
            if (!removed.waiter) {
                pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
                fprintf(stderr, "blorp: corrupted IO deadline queue entry (bug)\n");
                abort();
            }
        }
    }
    pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
    blorp_io_deadline_entry_release(&removed);
}

static long blorp_io_deadline_queue_count(void) {
    blorp_io_deadline_queue_ensure_init();
    pthread_mutex_lock(&__blorp_io_deadline_queue.lock);
    long count = (long)__blorp_io_deadline_queue.len;
    pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
    return count;
}

static uint64_t blorp_io_deadline_queue_drain(void) {
    blorp_io_deadline_queue_ensure_init();
    uint64_t now_ns = blorp_monotonic_now_ns();

    while (true) {
        pthread_mutex_lock(&__blorp_io_deadline_queue.lock);
        if (__blorp_io_deadline_queue.len == 0) {
            pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
            return 0;
        }
        blorp_IoWaiter* waiter = __blorp_io_deadline_queue.items[0];
        if (waiter->deadline_ns > now_ns) {
            uint64_t next_deadline = waiter->deadline_ns;
            pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
            return next_deadline;
        }
        blorp_IoDeadlineEntry expired = blorp_io_deadline_heap_pop_min_locked();
        pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);

        if (expired.waiter && expired.owner) {
            blorp_IoWaiterList timed_out = blorp_tcp_inner_extract_waiter(
                expired.owner, expired.waiter->kind, expired.waiter->generation,
                BLORP_IO_WAKE_TIMEOUT);
            blorp_io_waiter_wake_all(&timed_out);
        }
        blorp_io_deadline_entry_release(&expired);
    }
}

static void blorp_io_deadline_queue_clear(void) {
    blorp_io_deadline_queue_ensure_init();
    blorp_IoDeadlineEntry* removed = NULL;
    size_t removed_count = 0;
    pthread_mutex_lock(&__blorp_io_deadline_queue.lock);
    if (__blorp_io_deadline_queue.len > 0) {
        removed_count = __blorp_io_deadline_queue.len;
        removed = (blorp_IoDeadlineEntry*)calloc(
            removed_count, sizeof(blorp_IoDeadlineEntry));
        if (!removed) {
            pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
            fprintf(stderr, "blorp: out of memory clearing IO deadline queue\n");
            exit(1);
        }
    }
    for (size_t i = 0; i < __blorp_io_deadline_queue.len; i++) {
        blorp_IoWaiter* waiter = __blorp_io_deadline_queue.items[i];
        if (!waiter) continue;
        removed[i].waiter = waiter;
        removed[i].owner = waiter->deadline_owner;
        waiter->deadline_queued = false;
        waiter->deadline_index = -1;
        waiter->deadline_owner = NULL;
    }
    free(__blorp_io_deadline_queue.items);
    __blorp_io_deadline_queue.items = NULL;
    __blorp_io_deadline_queue.len = 0;
    __blorp_io_deadline_queue.cap = 0;
    pthread_mutex_unlock(&__blorp_io_deadline_queue.lock);
    for (size_t i = 0; i < removed_count; i++) {
        blorp_io_deadline_entry_release(&removed[i]);
    }
    free(removed);
}

// Park current fiber — yields back to scheduler.
// IMPORTANT: Caller must set parked=1 and set up wakeup mechanism BEFORE calling.
// This ensures the fiber is visible to wakers before it yields.
static void blorp_fiber_park(void) {
    blorp_Fiber* f = __blorp_current_fiber;
    if (!f) return;  // Safety: not in a fiber
    __blorp_scheduler_stat_inc(&global_scheduler_stats.fiber_parks);
    mco_result yield_res = mco_yield(f->coro);
    if (yield_res == MCO_STACK_OVERFLOW) {
        fprintf(stderr,
            "\nblorp: fiber stack overflow detected at yield\n"
            "  Fiber stack size is fixed at %zu bytes.\n",
            __blorp_fiber_stack_size);
        abort();
    }
    // Resumed here after wakeup
}

static blorp_IoWakeReason blorp_tcp_inner_park_current_fiber(
    blorp_TcpInner* inner,
    blorp_IoWaitKind kind,
    int fd,
    uint64_t generation,
    int interest,
    long timeout_ms
) {
    if (__blorp_cancel_current_task_if_requested()) {
        return BLORP_IO_WAKE_CANCELLED;
    }

    blorp_Fiber* self = __blorp_current_fiber;
    if (!inner || !self) return BLORP_IO_WAKE_NONE;

    pthread_mutex_lock(&inner->mutex);
    bool open = inner->state == BLORP_TCP_STATE_OPEN && inner->fd == fd &&
        inner->generation == generation;
    pthread_mutex_unlock(&inner->mutex);
    if (!open) return BLORP_IO_WAKE_CLOSED;

    uint64_t deadline_ns = 0;
    if (timeout_ms >= 0) {
        uint64_t now_ns = blorp_monotonic_now_ns();
        uint64_t timeout_ns = (uint64_t)timeout_ms * 1000000ULL;
        deadline_ns =
            timeout_ns > UINT64_MAX - now_ns ? UINT64_MAX : now_ns + timeout_ns;
    }

    blorp_IoWaiter* waiter =
        blorp_io_waiter_new(kind, self, generation, deadline_ns);
    blorp_IoWakeReason result = BLORP_IO_WAKE_NONE;

    __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
    if (blorp_tcp_inner_install_waiter(inner, waiter) != 0) {
        __atomic_store_n(&self->parked, 0, __ATOMIC_RELEASE);
        blorp_io_waiter_release(waiter);
        return BLORP_IO_WAKE_CLOSED;
    }

    // Readiness can arrive after reactor registration but before this waiter
    // is installed. Take that pending readiness before yielding so one-shot
    // readiness suppression cannot lose a wake.
    if (blorp_io_reactor_take_ready(fd, generation, interest) > 0) {
        (void)blorp_tcp_inner_remove_waiter(inner, waiter);
        __atomic_store_n(&self->parked, 0, __ATOMIC_RELEASE);
        blorp_io_waiter_release(waiter);
        return BLORP_IO_WAKE_READY;
    }

    if (deadline_ns != 0) blorp_io_deadline_queue_insert(waiter, inner);

    blorp_fiber_park();

    if (deadline_ns != 0) blorp_io_deadline_queue_remove(waiter);

    if (__blorp_is_cancelled()) {
        if (waiter->installed) {
            (void)blorp_tcp_inner_cancel_waiter(inner, waiter);
        }
        (void)__blorp_cancel_current_task_if_requested();
        blorp_io_waiter_release(waiter);
        return BLORP_IO_WAKE_CANCELLED;
    }

    if (waiter->wake_reason == BLORP_IO_WAKE_NONE && deadline_ns != 0) {
        blorp_IoWaiterList timed_out = blorp_tcp_inner_extract_waiter(
            inner, kind, generation, BLORP_IO_WAKE_TIMEOUT);
        blorp_io_waiter_wake_all(&timed_out);
    }

    if (waiter->wake_reason == BLORP_IO_WAKE_NONE) {
        (void)blorp_tcp_inner_remove_waiter(inner, waiter);
    }

    result = waiter->wake_reason;
    blorp_io_waiter_release(waiter);
    return result;
}

static void blorp_timer_heap_swap(size_t a, size_t b) {
    blorp_Fiber* tmp = __fiber_timer_queue.items[a];
    __fiber_timer_queue.items[a] = __fiber_timer_queue.items[b];
    __fiber_timer_queue.items[b] = tmp;
    __fiber_timer_queue.items[a]->timer_index = (long)a;
    __fiber_timer_queue.items[b]->timer_index = (long)b;
}

static void blorp_timer_heap_sift_up(size_t idx) {
    while (idx > 0) {
        size_t parent = (idx - 1) / 2;
        if (__fiber_timer_queue.items[parent]->wake_time_ns <=
            __fiber_timer_queue.items[idx]->wake_time_ns) {
            break;
        }
        blorp_timer_heap_swap(parent, idx);
        idx = parent;
    }
}

static void blorp_timer_heap_sift_down(size_t idx) {
    while (true) {
        size_t left = idx * 2 + 1;
        size_t right = left + 1;
        size_t smallest = idx;
        if (left < __fiber_timer_queue.len &&
            __fiber_timer_queue.items[left]->wake_time_ns <
                __fiber_timer_queue.items[smallest]->wake_time_ns) {
            smallest = left;
        }
        if (right < __fiber_timer_queue.len &&
            __fiber_timer_queue.items[right]->wake_time_ns <
                __fiber_timer_queue.items[smallest]->wake_time_ns) {
            smallest = right;
        }
        if (smallest == idx) break;
        blorp_timer_heap_swap(idx, smallest);
        idx = smallest;
    }
}

static void blorp_timer_heap_reserve(size_t needed) {
    if (__fiber_timer_queue.cap >= needed) return;
    size_t new_cap = __fiber_timer_queue.cap ? __fiber_timer_queue.cap * 2 : 64;
    while (new_cap < needed) new_cap *= 2;
    if (new_cap > SIZE_MAX / sizeof(blorp_Fiber*)) {
        fprintf(stderr, "blorp: timer queue capacity overflow\n");
        exit(1);
    }
    blorp_Fiber** new_items =
        (blorp_Fiber**)realloc(__fiber_timer_queue.items,
            new_cap * sizeof(blorp_Fiber*));
    if (!new_items) {
        fprintf(stderr, "blorp: out of memory (timer queue %zu entries)\n",
            new_cap);
        exit(1);
    }
    __fiber_timer_queue.items = new_items;
    __fiber_timer_queue.cap = new_cap;
}

static blorp_Fiber* blorp_timer_heap_pop_min(void) {
    if (__fiber_timer_queue.len == 0) return NULL;
    blorp_Fiber* min = __fiber_timer_queue.items[0];
    min->timer_index = -1;
    __fiber_timer_queue.len--;
    if (__fiber_timer_queue.len > 0) {
        __fiber_timer_queue.items[0] =
            __fiber_timer_queue.items[__fiber_timer_queue.len];
        __fiber_timer_queue.items[0]->timer_index = 0;
        blorp_timer_heap_sift_down(0);
    }
    return min;
}

static void blorp_timer_heap_remove_at(size_t idx) {
    if (idx >= __fiber_timer_queue.len) return;
    blorp_Fiber* removed = __fiber_timer_queue.items[idx];
    removed->timer_index = -1;
    __fiber_timer_queue.len--;
    if (idx == __fiber_timer_queue.len) return;
    __fiber_timer_queue.items[idx] =
        __fiber_timer_queue.items[__fiber_timer_queue.len];
    __fiber_timer_queue.items[idx]->timer_index = (long)idx;
    blorp_timer_heap_sift_down(idx);
    blorp_timer_heap_sift_up(idx);
}

// Insert fiber into the timer min-heap.
static void blorp_timer_queue_insert(blorp_Fiber* f) {
    __blorp_scheduler_stat_lock(
        &__fiber_timer_queue.lock,
        &global_scheduler_stats.timer_lock_contentions);
    bool changes_next_expiry =
        __fiber_timer_queue.len == 0 ||
        f->wake_time_ns < __fiber_timer_queue.items[0]->wake_time_ns;
    if (f->timer_index >= 0 &&
        (size_t)f->timer_index < __fiber_timer_queue.len &&
        __fiber_timer_queue.items[f->timer_index] == f) {
        blorp_timer_heap_remove_at((size_t)f->timer_index);
        changes_next_expiry =
            __fiber_timer_queue.len == 0 ||
            f->wake_time_ns < __fiber_timer_queue.items[0]->wake_time_ns;
    }
    blorp_timer_heap_reserve(__fiber_timer_queue.len + 1);
    size_t idx = __fiber_timer_queue.len++;
    __fiber_timer_queue.items[idx] = f;
    f->timer_index = (long)idx;
    blorp_timer_heap_sift_up(idx);
    __blorp_scheduler_stat_inc(&global_scheduler_stats.timer_inserts);
    pthread_mutex_unlock(&__fiber_timer_queue.lock);
    // Wake a worker only when the new timer changes the next deadline. Later
    // timers can wait for the existing sleeper to recompute the heap head.
    if (__blorp_pool && changes_next_expiry) blorp_pool_signal_any_worker();
}

// Remove a specific fiber from the timer queue (if present).
// Called when a fiber is woken by a non-timer mechanism (e.g., task completion)
// while also having a pending timer entry.
static void blorp_timer_queue_remove(blorp_Fiber* f) {
    __blorp_scheduler_stat_lock(
        &__fiber_timer_queue.lock,
        &global_scheduler_stats.timer_lock_contentions);
    if (f->timer_index >= 0) {
        size_t idx = (size_t)f->timer_index;
        if (idx < __fiber_timer_queue.len && __fiber_timer_queue.items[idx] == f) {
            blorp_timer_heap_remove_at(idx);
        } else {
            f->timer_index = -1;
        }
    }
    pthread_mutex_unlock(&__fiber_timer_queue.lock);
}

// Move expired timers to run queue. Returns next expiry time (0 if none).
static uint64_t blorp_timer_queue_drain(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t now_ns = (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
    uint64_t next_expiry = 0;

    __blorp_scheduler_stat_lock(
        &__fiber_timer_queue.lock,
        &global_scheduler_stats.timer_lock_contentions);
    blorp_Fiber* expired_head = NULL;
    blorp_Fiber* expired_tail = NULL;
    while (__fiber_timer_queue.len > 0 &&
           __fiber_timer_queue.items[0]->wake_time_ns <= now_ns) {
        blorp_Fiber* f = blorp_timer_heap_pop_min();
        __blorp_scheduler_stat_inc(&global_scheduler_stats.timer_expirations);
        f->timer_drain_next = NULL;
        if (expired_tail) {
            expired_tail->timer_drain_next = f;
        } else {
            expired_head = f;
        }
        expired_tail = f;
    }
    if (__fiber_timer_queue.len > 0) {
        next_expiry = __fiber_timer_queue.items[0]->wake_time_ns;
    }
    pthread_mutex_unlock(&__fiber_timer_queue.lock);

    while (expired_head) {
        blorp_Fiber* f = expired_head;
        expired_head = f->timer_drain_next;
        f->timer_drain_next = NULL;
        blorp_fiber_schedule(f);
    }
    return next_expiry;
}

// Pop a fiber from a run queue (non-blocking). Caller must hold queue->lock.
static void blorp_fiber_claim_ownerless(blorp_Fiber* f, long worker_id) {
    if (f && worker_id >= 0 && f->owner_worker_id < 0) {
        f->owner_worker_id = worker_id;
    }
}

static void blorp_fiber_run_queue_finish_pop(
    blorp_Fiber* f,
    long worker_id
) {
    if (!f) return;
    f->run_next = NULL;
    blorp_fiber_claim_ownerless(f, worker_id);
    __atomic_store_n(&f->queued, 0, __ATOMIC_RELEASE);
    __blorp_scheduler_stat_inc(&global_scheduler_stats.run_queue_pops);
    atomic_fetch_sub_explicit(
        &__fiber_runnable_count, 1, memory_order_release);
}

static blorp_Fiber* blorp_fiber_run_queue_pop(
    blorp_FiberRunQueue* queue,
    long worker_id
) {
    blorp_Fiber* f = queue->head;
    if (f) {
        queue->head = f->run_next;
        if (!queue->head) queue->tail = NULL;
        queue->fiber_count--;
        blorp_fiber_run_queue_finish_pop(f, worker_id);
    }
    return f;
}

// Work stealing is restricted to never-resumed fibers. Once a fiber has an
// owner, it must only resume on that owner so coroutine stacks remain
// thread-affine across park/wake cycles.
static blorp_Fiber* blorp_fiber_run_queue_steal_ownerless(
    blorp_FiberRunQueue* queue,
    long worker_id
) {
    blorp_Fiber* prev = NULL;
    blorp_Fiber* f = queue->head;
    while (f && f->owner_worker_id >= 0) {
        prev = f;
        f = f->run_next;
    }
    if (!f) return NULL;
    if (prev) {
        prev->run_next = f->run_next;
    } else {
        queue->head = f->run_next;
    }
    if (queue->tail == f) queue->tail = prev;
    queue->fiber_count--;
    blorp_fiber_run_queue_finish_pop(f, worker_id);
    return f;
}

// Pop a fiber from the fallback run queue. Caller must hold __fiber_run_queue.lock.
static blorp_Fiber* blorp_fiber_pop(void) {
    return blorp_fiber_run_queue_pop(
        &__fiber_run_queue, __blorp_current_worker_id);
}

static blorp_Fiber* blorp_fiber_take_all_queued(blorp_FiberRunQueue* queue) {
    __blorp_scheduler_stat_lock(
        &queue->lock, &global_scheduler_stats.run_queue_lock_contentions);
    blorp_Fiber* fibers = queue->head;
    long count = queue->fiber_count;
    queue->head = NULL;
    queue->tail = NULL;
    queue->fiber_count = 0;
    pthread_mutex_unlock(&queue->lock);
    if (count > 0) {
        atomic_fetch_sub_explicit(
            &__fiber_runnable_count, count, memory_order_release);
    }
    return fibers;
}

static void blorp_fiber_destroy_list(blorp_Fiber* fibers) {
    while (fibers) {
        blorp_Fiber* next = fibers->run_next;
        fibers->run_next = NULL;
        if (fibers->coro) { mco_destroy(fibers->coro); }
        blorp_fiber_object_recycle(fibers);
        fibers = next;
    }
}

// Task handle (ARC-managed)
typedef struct blorp_Task_s {
    blorp_Object header;
    pthread_mutex_t mutex;
    pthread_cond_t done_cond;
    bool completed;
    bool joined;            // True after result has been claimed by join/try_join
    void* result;           // The return value (ownership transferred on join)
    blorp_Closure* func;    // The closure to execute (retained)
    bool result_is_rc;      // True if result is a refcounted heap object
    blorp_Fiber* waiting_fiber;  // Fiber blocked on join (NULL if none)
    blorp_Fiber* task_fiber;     // Fiber executing the task, if any
    jmp_buf cancel_jmp;          // Escape point for cooperative cancellation
    bool cancel_jmp_ready;       // True while cancel_jmp is active
    blorp_CancelCleanupFrame* cleanup_stack;
    _Atomic int cancelled;  // Cooperative cancellation flag
} blorp_Task;

typedef enum {
    BLORP_TASK_BORROWS_CLOSURE,
    BLORP_TASK_OWNS_CLOSURE
} blorp_TaskClosureOwnership;

// Task destructor: release closure, destroy sync primitives.
// If result_is_rc is set and the result was never claimed via join,
// release the refcounted result to prevent leaks.
static void blorp_task_destructor(void* obj) {
    blorp_Task* task = (blorp_Task*)obj;
    if (task->result && task->result_is_rc && !task->joined) {
        blorp_release(task->result);
    }
    if (task->func) blorp_release(task->func);
    pthread_mutex_destroy(&task->mutex);
    pthread_cond_destroy(&task->done_cond);
}

static inline int __blorp_task_is_cancelled(blorp_Task* task) {
    if (!task) return 0;
    return atomic_load_explicit(&task->cancelled, memory_order_acquire);
}

// Check if the current task has been cancelled (called from blocking builtins)
static inline int __blorp_is_cancelled(void) {
    return __blorp_task_is_cancelled((blorp_Task*)__blorp_current_task);
}

void blorp_cleanup_release_arc_value(void* value) {
    if (value) blorp_release(value);
}

void blorp_cleanup_release_arc_only_value(void* value) {
    if (value) blorp_release_arc_only(value);
}

void __blorp_task_cleanup_push_slow(blorp_CancelCleanupFrame* frame,
                                    const void* slot, void* value,
                                    blorp_CancelCleanupFn release_value) {
    blorp_Task* task = (blorp_Task*)__blorp_current_task;
    if (!frame) return;
    frame->prev = NULL;
    frame->slot = slot;
    frame->value = value;
    frame->release_value = release_value;
    frame->active = false;
    if (!task || !slot || !release_value) return;
    frame->prev = task->cleanup_stack;
    frame->active = true;
    task->cleanup_stack = frame;
}

void __blorp_task_cleanup_pop_slot_slow(const void* slot) {
    blorp_Task* task = (blorp_Task*)__blorp_current_task;
    if (!task || !slot) return;
    blorp_CancelCleanupFrame** link = &task->cleanup_stack;
    while (*link) {
        blorp_CancelCleanupFrame* frame = *link;
        if (frame->slot == slot) {
            *link = frame->prev;
            frame->prev = NULL;
            frame->slot = NULL;
            frame->value = NULL;
            frame->release_value = NULL;
            frame->active = false;
            return;
        }
        link = &frame->prev;
    }
}

static inline void blorp_task_cleanup_push(blorp_CancelCleanupFrame* frame,
                                           const void* slot, void* value,
                                           blorp_CancelCleanupFn release_value) {
    if (__builtin_expect(__blorp_current_task != NULL, 0)) {
        __blorp_task_cleanup_push_slow(frame, slot, value, release_value);
    }
}

static inline void blorp_task_cleanup_pop_slot(const void* slot) {
    if (__builtin_expect(__blorp_current_task != NULL, 0)) {
        __blorp_task_cleanup_pop_slot_slow(slot);
    }
}

static void __blorp_task_cleanup_drain(blorp_Task* task) {
    if (!task) return;
    blorp_CancelCleanupFrame* frame = task->cleanup_stack;
    task->cleanup_stack = NULL;
    while (frame) {
        blorp_CancelCleanupFrame* next = frame->prev;
        if (frame->active && frame->release_value) {
            frame->release_value(frame->value);
        }
        frame->prev = NULL;
        frame->slot = NULL;
        frame->value = NULL;
        frame->release_value = NULL;
        frame->active = false;
        frame = next;
    }
}

// Cancellation is cooperative: blocking/yielding runtime operations are
// cancellation points. Once a task has an active runner, cancellation exits
// through the task runner so code after the cancellation point is not executed.
// Before jumping, drain compiler-registered task-local cleanup frames while the
// cancelled stack is still valid.
static int __blorp_cancel_current_task_if_requested(void) {
    blorp_Task* task = (blorp_Task*)__blorp_current_task;
    if (!__blorp_task_is_cancelled(task)) return 0;
    if (task->cancel_jmp_ready) {
        __blorp_task_cleanup_drain(task);
        longjmp(task->cancel_jmp, 1);
    }
    return 1;
}

static void __blorp_task_enter_runner(blorp_Task* task) {
    __blorp_current_task = task;
    if (__blorp_current_fiber) {
        pthread_mutex_lock(&task->mutex);
        task->task_fiber = __blorp_current_fiber;
        pthread_mutex_unlock(&task->mutex);
    }
}

static void __blorp_task_leave_runner(blorp_Task* task) {
    pthread_mutex_lock(&task->mutex);
    if (task->task_fiber == __blorp_current_fiber) {
        task->task_fiber = NULL;
    }
    task->cancel_jmp_ready = false;
    task->cleanup_stack = NULL;
    pthread_mutex_unlock(&task->mutex);
    __blorp_current_task = NULL;
}

static void __blorp_task_discard_result_locked(blorp_Task* task) {
    if (!task->joined && task->result && task->result_is_rc) {
        blorp_release(task->result);
    }
    task->result = NULL;
    task->joined = true;
}

static blorp_Result* blorp_task_result_ok(void* result, bool result_is_rc) {
    blorp_Result* joined = blorp_result_ok(result);
    joined->release_mask = result_is_rc && result ? 1UL : 0UL;
    return joined;
}

static void __blorp_task_wait_completed(blorp_Task* task) {
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&task->mutex);
    while (!task->completed) {
        if (self) {
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            task->waiting_fiber = self;
            pthread_mutex_unlock(&task->mutex);
            blorp_fiber_park();
            pthread_mutex_lock(&task->mutex);
            if (!task->completed && __blorp_is_cancelled()) {
                if (task->waiting_fiber == self) task->waiting_fiber = NULL;
                pthread_mutex_unlock(&task->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return;
            }
        } else {
            pthread_cond_wait(&task->done_cond, &task->mutex);
            if (!task->completed && __blorp_is_cancelled()) {
                pthread_mutex_unlock(&task->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return;
            }
        }
    }
    if (self && task->waiting_fiber == self) task->waiting_fiber = NULL;
    pthread_mutex_unlock(&task->mutex);
}

// Complete a task: store result, wake waiters (condvar + fiber)
static void __blorp_task_complete(blorp_Task* task, void* result) {
    pthread_mutex_lock(&task->mutex);
    task->result = result;
    task->completed = true;
    task->task_fiber = NULL;
    task->cancel_jmp_ready = false;
    blorp_Fiber* waiter = task->waiting_fiber;
    task->waiting_fiber = NULL;
    pthread_cond_broadcast(&task->done_cond);
    pthread_mutex_unlock(&task->mutex);
    // Wake fiber waiter (outside lock — schedule is lock-safe)
    if (waiter) blorp_fiber_schedule(waiter);
    // Release the task ref held by the worker/fiber
    blorp_release(task);
}

// Worker function for spawned tasks (work item path — non-fiber)
static void __blorp_task_worker(void* arg) {
    blorp_Task* task = (blorp_Task*)arg;
    __blorp_task_enter_runner(task);
    typedef void* (*fn0_t)(void*);
    fn0_t f = (fn0_t)task->func->func;
    void* result = NULL;
    if (setjmp(task->cancel_jmp) == 0) {
        task->cancel_jmp_ready = true;
        (void)__blorp_cancel_current_task_if_requested();
        result = f(task->func->env);
    }
    __blorp_task_leave_runner(task);
    __blorp_task_complete(task, result);
}

// Fiber entry function for spawned tasks
static void __blorp_task_fiber_entry(mco_coro* co) {
    blorp_Task* task = (blorp_Task*)mco_get_user_data(co);
    __blorp_task_enter_runner(task);
    typedef void* (*fn0_t)(void*);
    fn0_t f = (fn0_t)task->func->func;
    void* result = NULL;
    if (setjmp(task->cancel_jmp) == 0) {
        task->cancel_jmp_ready = true;
        (void)__blorp_cancel_current_task_if_requested();
        result = f(task->func->env);
    }
    __blorp_task_leave_runner(task);
    __blorp_task_complete(task, result);
}

// Common task allocation. Borrowed closure spawn retains the function for the
// task; owned closure spawn transfers the caller's closure reference directly.
static blorp_Task* __blorp_task_alloc(
    blorp_Closure* func,
    blorp_TaskClosureOwnership closure_ownership
) {
    __blorp_scheduler_stat_inc(&global_scheduler_stats.tasks_spawned);
    blorp_Task* task = (blorp_Task*)blorp_alloc(sizeof(blorp_Task));
    BLORP_SET_DESTRUCTOR(task, blorp_task_destructor);
    pthread_mutex_init(&task->mutex, NULL);
    pthread_cond_init(&task->done_cond, NULL);
    task->completed = false;
    task->joined = false;
    task->result = NULL;
    task->result_is_rc = false;
    task->func =
        closure_ownership == BLORP_TASK_OWNS_CLOSURE
            ? func
            : (blorp_Closure*)blorp_retain(func);
    task->waiting_fiber = NULL;
    task->task_fiber = NULL;
    task->cancel_jmp_ready = false;
    task->cleanup_stack = NULL;
    atomic_store_explicit(&task->cancelled, 0, memory_order_relaxed);
    return task;
}

static blorp_Task* __blorp_task_spawn_impl(
    blorp_Closure* func,
    blorp_TaskClosureOwnership closure_ownership,
    bool result_is_rc,
    blorp_TaskScheduleTarget schedule
) {
    pthread_once(&__blorp_pool_once, __blorp_pool_init_default);
    blorp_Task* task = __blorp_task_alloc(func, closure_ownership);
    task->result_is_rc = result_is_rc;
    // Retain task for the worker/fiber (released on completion)
    blorp_retain(task);
    if (__fibers_initialized) {
        // Create fiber for this task
        blorp_Fiber* fiber = blorp_fiber_create(__blorp_task_fiber_entry, task);
        if (fiber) {
            blorp_task_schedule_new_fiber(schedule, fiber);
            return task;
        }
        // Fallback to work item if fiber creation fails
    }
    __blorp_pool_submit_releasing_arg(__blorp_task_worker, task);
    return task;
}

// spawn(func) -> Task[T]. Retains the borrowed closure for the task.
void* blorp_task_spawn(blorp_Closure* func) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_BORROWS_CLOSURE, false, blorp_task_schedule_immediate());
}

// spawn_owned(func) -> Task[T]. Takes ownership of the caller's closure ref.
void* blorp_task_spawn_owned(blorp_Closure* func) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_OWNS_CLOSURE, false, blorp_task_schedule_immediate());
}

void* blorp_task_spawn_owned_in_batch(
    blorp_TaskBatch* batch,
    blorp_Closure* func
) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_OWNS_CLOSURE, false, blorp_task_schedule_batch(batch));
}

// Mark task result as refcounted (called by codegen after spawn)
void blorp_task_init_result_rc(void* t) {
    blorp_Task* task = (blorp_Task*)t;
    task->result_is_rc = true;
}

// Spawn a task and mark result as refcounted atomically (no race with worker)
void* blorp_task_spawn_rc(blorp_Closure* func) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_BORROWS_CLOSURE, true, blorp_task_schedule_immediate());
}

// Spawn a task, mark result as refcounted, and take ownership of the closure.
void* blorp_task_spawn_owned_rc(blorp_Closure* func) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_OWNS_CLOSURE, true, blorp_task_schedule_immediate());
}

void* blorp_task_spawn_owned_rc_in_batch(
    blorp_TaskBatch* batch,
    blorp_Closure* func
) {
    return __blorp_task_spawn_impl(
        func, BLORP_TASK_OWNS_CLOSURE, true, blorp_task_schedule_batch(batch));
}

// Cancel a task — sets the cancelled flag and wakes the task's fiber if parked.
// Cooperative: the task body sees cancellation at the next blocking point (sleep,
// recv, send) and returns early. Used by first: blocks to stop loser tasks.
void blorp_task_cancel(void* t) {
    blorp_Task* task = (blorp_Task*)t;
    if (!task) return;
    atomic_store_explicit(&task->cancelled, 1, memory_order_release);
    // Wake the task's own fiber if it is parked at a cancellation point.
    // The join waiter is separate and will be woken when the task completes.
    pthread_mutex_lock(&task->mutex);
    blorp_Fiber* task_fiber = task->task_fiber;
    pthread_cond_broadcast(&task->done_cond);
    if (task_fiber) blorp_fiber_schedule(task_fiber);
    pthread_mutex_unlock(&task->mutex);
}

// detach(closure) — detach: spawn task, release caller's ref immediately.
// The worker releases its own ref on completion. Task self-destructs when done.
void blorp_detach(void* fn) {
    blorp_Closure* closure = (blorp_Closure*)fn;
    blorp_Task* task = (blorp_Task*)blorp_task_spawn(closure);
    blorp_release(task);
    if (closure) blorp_release(closure);
}

// detach with result_is_rc set (for closures returning RC values)
void blorp_detach_rc(void* fn) {
    blorp_Closure* closure = (blorp_Closure*)fn;
    blorp_Task* task = (blorp_Task*)blorp_task_spawn_rc(closure);
    blorp_release(task);
    if (closure) blorp_release(closure);
}

// join(task) -> Result[T, String]
// Ownership transfer: takes the result from the task (sets task->result = NULL).
// Does NOT retain the result — it may be a boxed primitive, not a heap object.
// Double-join returns Err("task already joined").
void* blorp_task_join(void* t) {
    if (__blorp_cancel_current_task_if_requested()) {
        return blorp_result_err(blorp_string_literal("task cancelled"));
    }
    blorp_Task* task = (blorp_Task*)t;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&task->mutex);
    if (task->joined) {
        pthread_mutex_unlock(&task->mutex);
        return blorp_result_err(blorp_string_literal("task already joined"));
    }
    if (!task->completed && self) {
        // Fiber path: set parked BEFORE inserting into wakeup structure
        __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
        task->waiting_fiber = self;
        pthread_mutex_unlock(&task->mutex);
        blorp_fiber_park();
        pthread_mutex_lock(&task->mutex);
        if (task->waiting_fiber == self) task->waiting_fiber = NULL;
        if (__blorp_is_cancelled()) {
            pthread_mutex_unlock(&task->mutex);
            if (__blorp_cancel_current_task_if_requested()) {
                return blorp_result_err(blorp_string_literal("task cancelled"));
            }
            pthread_mutex_lock(&task->mutex);
        }
    } else {
        while (!task->completed) {
            pthread_cond_wait(&task->done_cond, &task->mutex);
            if (!task->completed && __blorp_is_cancelled()) {
                pthread_mutex_unlock(&task->mutex);
                if (__blorp_cancel_current_task_if_requested()) {
                    return blorp_result_err(blorp_string_literal("task cancelled"));
                }
                pthread_mutex_lock(&task->mutex);
            }
        }
    }
    void* result = task->result;
    bool result_is_rc = task->result_is_rc;
    task->result = NULL;
    task->joined = true;
    pthread_mutex_unlock(&task->mutex);
    return blorp_task_result_ok(result, result_is_rc);
}

// try_join(task) -> Option[Result[T, String]]
// Same ownership transfer model as task_join.
// Double-join returns Some(Err("task already joined")).
void* blorp_task_try_join(void* t) {
    blorp_Task* task = (blorp_Task*)t;
    pthread_mutex_lock(&task->mutex);
    if (task->joined) {
        pthread_mutex_unlock(&task->mutex);
        blorp_Option* opt = blorp_option_some(blorp_result_err(blorp_string_literal("task already joined")));
        opt->release_mask = 1UL;
        return opt;
    }
    if (!task->completed) {
        pthread_mutex_unlock(&task->mutex);
        return blorp_option_none();
    }
    void* result = task->result;
    bool result_is_rc = task->result_is_rc;
    task->result = NULL;
    task->joined = true;
    pthread_mutex_unlock(&task->mutex);
    blorp_Option* opt = blorp_option_some(
        blorp_task_result_ok(result, result_is_rc));
    opt->release_mask = 1UL;
    return opt;
}

// concurrent_join(task, timeout_ms) -> Result[T, ConcurrencyError]
// timeout_ms < 0 means no timeout (wait forever).
// Returns Ok(result) on success, Err(Timeout) on timeout.
// Same ownership transfer as task_join.
void* blorp_concurrent_join(void* t, long timeout_ms) {
    if (__blorp_cancel_current_task_if_requested()) {
        return blorp_result_err((void*)blorp_Cancelled);
    }
    blorp_Task* task = (blorp_Task*)t;
    blorp_Fiber* self = __blorp_current_fiber;

    pthread_mutex_lock(&task->mutex);
    if (!task->completed && self) {
        // Fiber path: set parked BEFORE inserting into wakeup structures
        __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
        task->waiting_fiber = self;
        if (timeout_ms >= 0) {
            // Timed join: also insert into timer queue as a deadline
            struct timespec now_mono;
            clock_gettime(CLOCK_MONOTONIC, &now_mono);
            self->wake_time_ns = (uint64_t)now_mono.tv_sec * 1000000000ULL
                + (uint64_t)now_mono.tv_nsec + (uint64_t)timeout_ms * 1000000ULL;
            blorp_timer_queue_insert(self);
        }
        pthread_mutex_unlock(&task->mutex);
        blorp_fiber_park();
        // Resumed: either task completed or timer expired
        if (timeout_ms >= 0) {
            // Remove from timer queue in case task completed before timer fired
            blorp_timer_queue_remove(self);
        }
        pthread_mutex_lock(&task->mutex);
        task->waiting_fiber = NULL;
        if (__blorp_is_cancelled()) {
            pthread_mutex_unlock(&task->mutex);
            (void)__blorp_cancel_current_task_if_requested();
            return blorp_result_err((void*)blorp_Cancelled);
        }
        if (!task->completed) {
            pthread_mutex_unlock(&task->mutex);
            blorp_task_cancel(task);
            __blorp_task_wait_completed(task);
            pthread_mutex_lock(&task->mutex);
            __blorp_task_discard_result_locked(task);
            pthread_mutex_unlock(&task->mutex);
            return blorp_result_err((void*)blorp_Timeout);
        }
    } else if (!task->completed) {
        if (timeout_ms >= 0) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_sec += timeout_ms / 1000;
            ts.tv_nsec += (timeout_ms % 1000) * 1000000L;
            if (ts.tv_nsec >= 1000000000L) {
                ts.tv_sec++;
                ts.tv_nsec -= 1000000000L;
            }
            int ret = 0;
            while (!task->completed && ret == 0) {
                ret = pthread_cond_timedwait(&task->done_cond, &task->mutex, &ts);
            }
            if (!task->completed) {
                pthread_mutex_unlock(&task->mutex);
                blorp_task_cancel(task);
                __blorp_task_wait_completed(task);
                pthread_mutex_lock(&task->mutex);
                __blorp_task_discard_result_locked(task);
                pthread_mutex_unlock(&task->mutex);
                return blorp_result_err((void*)blorp_Timeout);
            }
        } else {
            while (!task->completed) {
                pthread_cond_wait(&task->done_cond, &task->mutex);
            }
        }
    }
    void* result = task->result;
    bool result_is_rc = task->result_is_rc;
    task->result = NULL;
    task->joined = true;
    pthread_mutex_unlock(&task->mutex);
    return blorp_task_result_ok(result, result_is_rc);
}

// sleep(ms) — fiber-aware: parks fiber with timer, or OS sleep as fallback
void blorp_sleep(long ms) {
    if (__blorp_cancel_current_task_if_requested()) return;
    if (ms <= 0) return;
    blorp_Fiber* self = __blorp_current_fiber;
    if (self) {
        // Fiber path: set parked BEFORE inserting into timer queue
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        self->wake_time_ns = (uint64_t)now.tv_sec * 1000000000ULL
                           + (uint64_t)now.tv_nsec
                           + (uint64_t)ms * 1000000ULL;
        __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
        blorp_timer_queue_insert(self);
        blorp_fiber_park();
        blorp_timer_queue_remove(self);
        (void)__blorp_cancel_current_task_if_requested();
        return;
    }
    // Fallback: OS-level sleep (main thread or non-fiber context)
    struct timespec ts, rem;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    while (nanosleep(&ts, &rem) == -1 && errno == EINTR) ts = rem;
    (void)__blorp_cancel_current_task_if_requested();
}

// max_threads() -> Int
long blorp_max_threads(void) {
    if (__blorp_max_threads_value > 0) return __blorp_max_threads_value;
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? n : 4;
}

// ============================================================================
// Channel[T] — Bounded MPMC channel
// ============================================================================

typedef struct {
    blorp_Object header;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;   // signaled on send or close
    pthread_cond_t not_full;    // signaled on recv or close
    void** buffer;              // circular buffer
    long capacity, count, head, tail;
    bool closed;
    void (*elem_release)(void*);  // release function for refcounted element types
    // Fiber wait queues
    blorp_Fiber* send_waiters_head;  // fibers blocked on full channel
    blorp_Fiber* send_waiters_tail;
    blorp_Fiber* recv_waiters_head;  // fibers blocked on empty channel
    blorp_Fiber* recv_waiters_tail;
} blorp_Channel;

static void blorp_channel_destructor(void* obj) {
    blorp_Channel* ch = (blorp_Channel*)obj;
    // Invariant: no fibers should be waiting on a channel when it's freed.
    // In blorp, closures capture channels by value (retain), so a fiber blocked
    // on recv/send holds a ref that prevents the destructor from running.
    // Timed operations (recv_timeout/send_timeout) remove themselves from the
    // wait queue on timeout (via __ch_fiber_remove), so they don't leave stale
    // entries. If this assertion fires, there's a ref-counting bug.
    if (ch->send_waiters_head || ch->recv_waiters_head) {
        fprintf(stderr, "blorp: channel destructor called with waiting fibers (bug)\n");
    }
    // Release unconsumed buffered values if elem_release is set
    if (ch->elem_release) {
        while (ch->count > 0) {
            void* val = ch->buffer[ch->head];
            ch->head = (ch->head + 1) % ch->capacity;
            ch->count--;
            if (val) ch->elem_release(val);
        }
    }
    free(ch->buffer);
    pthread_mutex_destroy(&ch->mutex);
    pthread_cond_destroy(&ch->not_empty);
    pthread_cond_destroy(&ch->not_full);
}

// channel(capacity) -> Channel[T]
void* blorp_channel_new(long capacity) {
    if (capacity < 1) capacity = 1;
    blorp_Channel* ch = (blorp_Channel*)blorp_alloc(sizeof(blorp_Channel));
    BLORP_TAG(ch, "Channel");
    BLORP_SET_DESTRUCTOR(ch, blorp_channel_destructor);
    pthread_mutex_init(&ch->mutex, NULL);
    pthread_cond_init(&ch->not_empty, NULL);
    pthread_cond_init(&ch->not_full, NULL);
    ch->buffer = (void**)blorp_calloc_checked(capacity, sizeof(void*));
    ch->capacity = capacity;
    ch->count = 0;
    ch->head = 0;
    ch->tail = 0;
    ch->closed = false;
    ch->elem_release = NULL;
    ch->send_waiters_head = NULL;
    ch->send_waiters_tail = NULL;
    ch->recv_waiters_head = NULL;
    ch->recv_waiters_tail = NULL;
    return ch;
}

// Set elem_release on a channel (called by codegen for refcounted element types)
void blorp_channel_init_elem_release(blorp_Channel* ch, void (*release_fn)(void*)) {
    if (ch) ch->elem_release = release_fn;
}

// Helper: enqueue fiber to channel wait list (caller holds ch->mutex)
static void __ch_fiber_enqueue(blorp_Fiber** head, blorp_Fiber** tail, blorp_Fiber* f) {
    f->wait_next = NULL;
    if (*tail) { (*tail)->wait_next = f; } else { *head = f; }
    *tail = f;
}

// Helper: dequeue one fiber from channel wait list (caller holds ch->mutex)
static blorp_Fiber* __ch_fiber_dequeue(blorp_Fiber** head, blorp_Fiber** tail) {
    blorp_Fiber* f = *head;
    if (f) {
        *head = f->wait_next;
        if (!*head) *tail = NULL;
        f->wait_next = NULL;
    }
    return f;
}

// Helper: remove a specific fiber from a channel wait list (caller holds ch->mutex).
// Used when a fiber wakes from timeout and must be removed from the wait queue
// to prevent use-after-free when a future send/recv dequeues the stale pointer.
static void __ch_fiber_remove(blorp_Fiber** head, blorp_Fiber** tail, blorp_Fiber* f) {
    blorp_Fiber** pp = head;
    blorp_Fiber* prev = NULL;
    while (*pp) {
        if (*pp == f) {
            *pp = f->wait_next;
            if (*tail == f) *tail = prev;
            if (!*head) *tail = NULL;
            f->wait_next = NULL;
            return;
        }
        prev = *pp;
        pp = &(*pp)->wait_next;
    }
}

/// Helper: wake all fibers in a wait list (call OUTSIDE ch->mutex to avoid nested locks)
static void __ch_fiber_wake_all(blorp_Fiber** head, blorp_Fiber** tail) {
    while (*head) {
        blorp_Fiber* f = *head;
        *head = f->wait_next;
        f->wait_next = NULL;
        blorp_fiber_schedule(f);
    }
    *tail = NULL;
}

// send(ch, value) -> Bool  (blocking, false if closed)
long blorp_channel_send(void* c, void* value) {
    if (__blorp_cancel_current_task_if_requested()) return 0;
    blorp_Channel* ch = (blorp_Channel*)c;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&ch->mutex);

    while (ch->count == ch->capacity && !ch->closed) {
        if (self) {
            // Fiber path: set parked BEFORE enqueueing, unlock AFTER yield
            // to prevent waker from resuming fiber before it suspends
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            __ch_fiber_enqueue(&ch->send_waiters_head, &ch->send_waiters_tail, self);
            // NOTE: We hold the mutex through mco_yield. The waker (recv side)
            // dequeues the fiber while holding the mutex, then schedules it AFTER
            // releasing the mutex. Since we yield here, the mutex is "held" by
            // this fiber's stack frame but the fiber is suspended. The waker
            // acquires the mutex, dequeues, releases mutex, then schedules.
            // When this fiber resumes, it continues here and re-locks the mutex.
            pthread_mutex_unlock(&ch->mutex);
            blorp_fiber_park();
            pthread_mutex_lock(&ch->mutex);
            __ch_fiber_remove(&ch->send_waiters_head, &ch->send_waiters_tail, self);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return 0;
            }
        } else {
            pthread_cond_wait(&ch->not_full, &ch->mutex);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return 0;
            }
        }
    }
    if (ch->closed) {
        pthread_mutex_unlock(&ch->mutex);
        return 0; // false
    }
    // Retain refcounted values — caller keeps its reference, channel gets its own
    if (ch->elem_release && value) blorp_retain(value);
    ch->buffer[ch->tail] = value;
    ch->tail = (ch->tail + 1) % ch->capacity;
    ch->count++;
    // Wake one recv waiter (fiber or condvar)
    blorp_Fiber* recv_waiter = __ch_fiber_dequeue(&ch->recv_waiters_head, &ch->recv_waiters_tail);
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
    if (recv_waiter) blorp_fiber_schedule(recv_waiter);
    return 1; // true
}

// recv(ch) -> Option[T]  (blocking, None if closed+empty)
void* blorp_channel_recv(void* c) {
    if (__blorp_cancel_current_task_if_requested()) return blorp_option_none();
    blorp_Channel* ch = (blorp_Channel*)c;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&ch->mutex);

    while (ch->count == 0 && !ch->closed) {
        if (self) {
            // Fiber path: set parked BEFORE enqueueing
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            __ch_fiber_enqueue(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            pthread_mutex_unlock(&ch->mutex);
            blorp_fiber_park();
            pthread_mutex_lock(&ch->mutex);
            __ch_fiber_remove(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return blorp_option_none();
            }
        } else {
            pthread_cond_wait(&ch->not_empty, &ch->mutex);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return blorp_option_none();
            }
        }
    }
    if (ch->count == 0) {
        pthread_mutex_unlock(&ch->mutex);
        return blorp_option_none();
    }
    void* value = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    // Wake one send waiter (fiber or condvar)
    blorp_Fiber* send_waiter = __ch_fiber_dequeue(&ch->send_waiters_head, &ch->send_waiters_tail);
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    if (send_waiter) blorp_fiber_schedule(send_waiter);
    blorp_Option* opt = blorp_option_some(value);
    if (ch->elem_release) opt->release_mask = 1UL;
    return opt;
}

// try_send(ch, value) -> Bool  (non-blocking, false if full/closed)
long blorp_channel_try_send(void* c, void* value) {
    blorp_Channel* ch = (blorp_Channel*)c;
    pthread_mutex_lock(&ch->mutex);
    if (ch->closed || ch->count == ch->capacity) {
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    // Retain refcounted values — caller keeps its reference, channel gets its own
    if (ch->elem_release && value) blorp_retain(value);
    ch->buffer[ch->tail] = value;
    ch->tail = (ch->tail + 1) % ch->capacity;
    ch->count++;
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
    return 1;
}

// Internal: non-blocking recv without Option allocation.
// Returns true and sets *out if a value was received, false when empty.
bool blorp_channel_try_recv_raw(blorp_Channel* ch, void** out) {
    pthread_mutex_lock(&ch->mutex);
    if (ch->count == 0) {
        pthread_mutex_unlock(&ch->mutex);
        return false;
    }
    *out = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    return true;
}

// try_recv(ch) -> Option[T]  (non-blocking, None if empty)
void* blorp_channel_try_recv(void* c) {
    blorp_Channel* ch = (blorp_Channel*)c;
    void* value = NULL;
    if (!blorp_channel_try_recv_raw(ch, &value)) return blorp_option_none();
    blorp_Option* opt = blorp_option_some(value);
    if (ch->elem_release) opt->release_mask = 1UL;
    return opt;
}

// Internal: timed recv without Option allocation.
// Returns true and sets *out if a value was received, false on timeout/closed.
bool blorp_channel_recv_timeout_raw(blorp_Channel* ch, long timeout_ms, void** out) {
    if (__blorp_cancel_current_task_if_requested()) return false;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&ch->mutex);

    if (ch->count == 0 && !ch->closed) {
        if (self) {
            // Fiber path: park with timer for wakeup on timeout
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            self->wake_time_ns = (uint64_t)now.tv_sec * 1000000000ULL
                               + (uint64_t)now.tv_nsec
                               + (uint64_t)timeout_ms * 1000000ULL;
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            __ch_fiber_enqueue(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            blorp_timer_queue_insert(self);
            pthread_mutex_unlock(&ch->mutex);
            blorp_fiber_park();
            // Woken by either: data arrived (sender dequeued us) or timer expired.
            // Remove from both queues — the waker removed us from one, but we may
            // still be in the other. Both removes are no-ops if already removed.
            blorp_timer_queue_remove(self);
            pthread_mutex_lock(&ch->mutex);
            __ch_fiber_remove(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return false;
            }
        } else {
            // Thread path: timed condvar wait
            struct timespec deadline;
            clock_gettime(CLOCK_REALTIME, &deadline);
            deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
            deadline.tv_sec += timeout_ms / 1000 + deadline.tv_nsec / 1000000000L;
            deadline.tv_nsec %= 1000000000L;
            pthread_cond_timedwait(&ch->not_empty, &ch->mutex, &deadline);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return false;
            }
        }
    }
    if (ch->count == 0) {
        pthread_mutex_unlock(&ch->mutex);
        return false;
    }
    *out = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    blorp_Fiber* send_waiter = __ch_fiber_dequeue(&ch->send_waiters_head, &ch->send_waiters_tail);
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    if (send_waiter) blorp_fiber_schedule(send_waiter);
    return true;
}

// recv_timeout(ch, ms) -> Option[T]  (blocking with timeout, None if timeout/closed)
void* blorp_channel_recv_timeout(void* c, long timeout_ms) {
    blorp_Channel* ch = (blorp_Channel*)c;
    void* value = NULL;
    if (!blorp_channel_recv_timeout_raw(ch, timeout_ms, &value)) return blorp_option_none();
    blorp_Option* opt = blorp_option_some(value);
    if (ch->elem_release) opt->release_mask = 1UL;
    return opt;
}

// send_timeout(ch, value, ms) -> Bool  (blocking with timeout, false if timeout/closed)
long blorp_channel_send_timeout(void* c, void* value, long timeout_ms) {
    if (__blorp_cancel_current_task_if_requested()) return 0;
    blorp_Channel* ch = (blorp_Channel*)c;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&ch->mutex);

    if (ch->count == ch->capacity && !ch->closed) {
        if (self) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            self->wake_time_ns = (uint64_t)now.tv_sec * 1000000000ULL
                               + (uint64_t)now.tv_nsec
                               + (uint64_t)timeout_ms * 1000000ULL;
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            __ch_fiber_enqueue(&ch->send_waiters_head, &ch->send_waiters_tail, self);
            blorp_timer_queue_insert(self);
            pthread_mutex_unlock(&ch->mutex);
            blorp_fiber_park();
            // Woken by either: space freed (receiver dequeued us) or timer expired.
            // Remove from both queues to prevent stale pointer issues.
            blorp_timer_queue_remove(self);
            pthread_mutex_lock(&ch->mutex);
            __ch_fiber_remove(&ch->send_waiters_head, &ch->send_waiters_tail, self);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return 0;
            }
        } else {
            struct timespec deadline;
            clock_gettime(CLOCK_REALTIME, &deadline);
            deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
            deadline.tv_sec += timeout_ms / 1000 + deadline.tv_nsec / 1000000000L;
            deadline.tv_nsec %= 1000000000L;
            pthread_cond_timedwait(&ch->not_full, &ch->mutex, &deadline);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return 0;
            }
        }
    }
    if (ch->closed || ch->count == ch->capacity) {
        pthread_mutex_unlock(&ch->mutex);
        return 0;
    }
    if (ch->elem_release && value) blorp_retain(value);
    ch->buffer[ch->tail] = value;
    ch->tail = (ch->tail + 1) % ch->capacity;
    ch->count++;
    blorp_Fiber* recv_waiter = __ch_fiber_dequeue(&ch->recv_waiters_head, &ch->recv_waiters_tail);
    pthread_cond_signal(&ch->not_empty);
    pthread_mutex_unlock(&ch->mutex);
    if (recv_waiter) blorp_fiber_schedule(recv_waiter);
    return 1;
}

// close(ch) -> Void  (wake all waiters)
void blorp_channel_close(void* c) {
    blorp_Channel* ch = (blorp_Channel*)c;
    pthread_mutex_lock(&ch->mutex);
    ch->closed = true;
    // Collect fiber waiters under lock, then wake outside to avoid nested lock acquisition
    blorp_Fiber* send_list = ch->send_waiters_head;
    ch->send_waiters_head = ch->send_waiters_tail = NULL;
    blorp_Fiber* recv_list = ch->recv_waiters_head;
    ch->recv_waiters_head = ch->recv_waiters_tail = NULL;
    pthread_cond_broadcast(&ch->not_empty);
    pthread_cond_broadcast(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    // Schedule collected fibers outside ch->mutex
    while (send_list) {
        blorp_Fiber* f = send_list;
        send_list = f->wait_next;
        f->wait_next = NULL;
        blorp_fiber_schedule(f);
    }
    while (recv_list) {
        blorp_Fiber* f = recv_list;
        recv_list = f->wait_next;
        f->wait_next = NULL;
        blorp_fiber_schedule(f);
    }
}

// Internal: blocking recv for for-in loop (avoids Option allocation overhead).
// Returns true and sets *out if a value was received, false when closed+empty.
bool blorp_channel_recv_raw(blorp_Channel* ch, void** out) {
    if (__blorp_cancel_current_task_if_requested()) return false;
    blorp_Fiber* self = __blorp_current_fiber;
    pthread_mutex_lock(&ch->mutex);
    while (ch->count == 0 && !ch->closed) {
        if (self) {
            __atomic_store_n(&self->parked, 1, __ATOMIC_RELEASE);
            __ch_fiber_enqueue(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            pthread_mutex_unlock(&ch->mutex);
            blorp_fiber_park();
            pthread_mutex_lock(&ch->mutex);
            __ch_fiber_remove(&ch->recv_waiters_head, &ch->recv_waiters_tail, self);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return false;
            }
        } else {
            pthread_cond_wait(&ch->not_empty, &ch->mutex);
            if (__blorp_is_cancelled()) {
                pthread_mutex_unlock(&ch->mutex);
                (void)__blorp_cancel_current_task_if_requested();
                return false;
            }
        }
    }
    if (ch->count == 0) {
        pthread_mutex_unlock(&ch->mutex);
        return false;
    }
    *out = ch->buffer[ch->head];
    ch->head = (ch->head + 1) % ch->capacity;
    ch->count--;
    blorp_Fiber* send_waiter = __ch_fiber_dequeue(&ch->send_waiters_head, &ch->send_waiters_tail);
    pthread_cond_signal(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    if (send_waiter) blorp_fiber_schedule(send_waiter);
    return true;
}

static inline long blorp_channel_unbox_long(void* value) {
    return (long)value;
}

static inline int8_t blorp_channel_unbox_int8(void* value) {
    return (int8_t)(intptr_t)value;
}

static inline int16_t blorp_channel_unbox_int16(void* value) {
    return (int16_t)(intptr_t)value;
}

static inline int32_t blorp_channel_unbox_int32(void* value) {
    return (int32_t)(intptr_t)value;
}

static inline uint8_t blorp_channel_unbox_uint8(void* value) {
    return (uint8_t)(uintptr_t)value;
}

static inline uint16_t blorp_channel_unbox_uint16(void* value) {
    return (uint16_t)(uintptr_t)value;
}

static inline uint32_t blorp_channel_unbox_uint32(void* value) {
    return (uint32_t)(uintptr_t)value;
}

static inline uint64_t blorp_channel_unbox_uint64(void* value) {
    return (uint64_t)(uintptr_t)value;
}

static inline long blorp_channel_unbox_bool(void* value) {
    return value ? 1L : 0L;
}

static inline void* blorp_stream_box_long(long value) {
    return (void*)value;
}

static inline void* blorp_stream_box_int8(int8_t value) {
    return (void*)(intptr_t)value;
}

static inline void* blorp_stream_box_int16(int16_t value) {
    return (void*)(intptr_t)value;
}

static inline void* blorp_stream_box_int32(int32_t value) {
    return (void*)(intptr_t)value;
}

static inline void* blorp_stream_box_uint8(uint8_t value) {
    return (void*)(uintptr_t)value;
}

static inline void* blorp_stream_box_uint16(uint16_t value) {
    return (void*)(uintptr_t)value;
}

static inline void* blorp_stream_box_uint32(uint32_t value) {
    return (void*)(uintptr_t)value;
}

static inline void* blorp_stream_box_uint64(uint64_t value) {
    return (void*)(uintptr_t)value;
}

static inline void* blorp_stream_box_bool(long value) {
    return (void*)(value ? 1L : 0L);
}

#define BLORP_DEFINE_CHANNEL_STACK_OPTION(PUBLIC_SUFFIX, STACK_SUFFIX, NAME, CTYPE, UNBOX) \
blorp_StackOption_##NAME blorp_channel_recv_##PUBLIC_SUFFIX(void* c) { \
    void* value = NULL; \
    if (!blorp_channel_recv_raw((blorp_Channel*)c, &value)) return blorp_stack_option_##STACK_SUFFIX##_none(); \
    return blorp_stack_option_##STACK_SUFFIX##_some((CTYPE)UNBOX(value)); \
} \
blorp_StackOption_##NAME blorp_channel_try_recv_##PUBLIC_SUFFIX(void* c) { \
    void* value = NULL; \
    if (!blorp_channel_try_recv_raw((blorp_Channel*)c, &value)) return blorp_stack_option_##STACK_SUFFIX##_none(); \
    return blorp_stack_option_##STACK_SUFFIX##_some((CTYPE)UNBOX(value)); \
} \
blorp_StackOption_##NAME blorp_channel_recv_timeout_##PUBLIC_SUFFIX(void* c, long timeout_ms) { \
    void* value = NULL; \
    if (!blorp_channel_recv_timeout_raw((blorp_Channel*)c, timeout_ms, &value)) return blorp_stack_option_##STACK_SUFFIX##_none(); \
    return blorp_stack_option_##STACK_SUFFIX##_some((CTYPE)UNBOX(value)); \
}

BLORP_DEFINE_CHANNEL_STACK_OPTION(int, int, Int, long, blorp_channel_unbox_long)
BLORP_DEFINE_CHANNEL_STACK_OPTION(int8, int8, Int8, int8_t, blorp_channel_unbox_int8)
BLORP_DEFINE_CHANNEL_STACK_OPTION(int16, int16, Int16, int16_t, blorp_channel_unbox_int16)
BLORP_DEFINE_CHANNEL_STACK_OPTION(int32, int32, Int32, int32_t, blorp_channel_unbox_int32)
BLORP_DEFINE_CHANNEL_STACK_OPTION(int64, int64, Int64, long, blorp_channel_unbox_long)
BLORP_DEFINE_CHANNEL_STACK_OPTION(uint8, uint8, UInt8, uint8_t, blorp_channel_unbox_uint8)
BLORP_DEFINE_CHANNEL_STACK_OPTION(uint16, uint16, UInt16, uint16_t, blorp_channel_unbox_uint16)
BLORP_DEFINE_CHANNEL_STACK_OPTION(uint32, uint32, UInt32, uint32_t, blorp_channel_unbox_uint32)
BLORP_DEFINE_CHANNEL_STACK_OPTION(uint64, uint64, UInt64, uint64_t, blorp_channel_unbox_uint64)
BLORP_DEFINE_CHANNEL_STACK_OPTION(float, float, Float, double, blorp_unbox_float)
BLORP_DEFINE_CHANNEL_STACK_OPTION(bool, bool, Bool, long, blorp_channel_unbox_bool)
BLORP_DEFINE_CHANNEL_STACK_OPTION(char, char, Char, int32_t, blorp_channel_unbox_int32)
BLORP_DEFINE_CHANNEL_STACK_OPTION(f32, float32, Float32, float, blorp_unbox_float32)
#ifdef __FLT16_MAX__
BLORP_DEFINE_CHANNEL_STACK_OPTION(f16, float16, Float16, _Float16, blorp_unbox_float16)
#endif

#undef BLORP_DEFINE_CHANNEL_STACK_OPTION

void* blorp_channel_recv_nullable(void* c) {
    void* value = NULL;
    if (!blorp_channel_recv_raw((blorp_Channel*)c, &value)) return NULL;
    return value;
}

void* blorp_channel_try_recv_nullable(void* c) {
    void* value = NULL;
    if (!blorp_channel_try_recv_raw((blorp_Channel*)c, &value)) return NULL;
    return value;
}

void* blorp_channel_recv_timeout_nullable(void* c, long timeout_ms) {
    void* value = NULL;
    if (!blorp_channel_recv_timeout_raw((blorp_Channel*)c, timeout_ms, &value)) return NULL;
    return value;
}

// Helper: call a closure with zero arguments
static inline void* blorp_call0(blorp_Closure* closure) {
    typedef void* (*fn0_t)(void*);
    fn0_t f = (fn0_t)closure->func;
    return f(closure->env);
}

// ============================================================================
// Parallel List Operations — True Thread Pool Parallelism
// ============================================================================

#define BLORP_PAR_STACK_CHUNKS 64
#define BLORP_LPAR_MIN_CHUNK 64

typedef void (*blorp_LParallelChunkWorker)(void* arg);
typedef void (*blorp_LParallelChunkInit)(
    void* chunk,
    long index,
    long start,
    long end,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count,
    void* ctx
);

typedef struct {
    long len;
    long num_chunks;
    long chunk_size;
    size_t chunk_bytes;
    void* chunks;
    blorp_WorkItem* items;
    bool heap_scoped_work;
    pthread_mutex_t done_lock;
    pthread_cond_t done_cond;
    long done_count;
} blorp_LParallelPlan;

static bool __blorp_lparallel_plan_init(
    blorp_LParallelPlan* plan,
    long len,
    long max_threads,
    size_t chunk_bytes,
    void* stack_chunks,
    blorp_WorkItem* stack_items
) {
    pthread_once(&__blorp_pool_once, __blorp_pool_init_default);
    long num_threads = max_threads > 0 ? max_threads : (__blorp_pool ? __blorp_pool->num_threads : 1);
    if (len < BLORP_LPAR_MIN_CHUNK * 2 || num_threads <= 1 || !__blorp_pool) {
        return false;
    }

    long num_chunks = num_threads;
    if (num_chunks > len / BLORP_LPAR_MIN_CHUNK) num_chunks = len / BLORP_LPAR_MIN_CHUNK;
    if (num_chunks < 2) num_chunks = 2;

    plan->len = len;
    plan->num_chunks = num_chunks;
    plan->chunk_size = len / num_chunks;
    plan->chunk_bytes = chunk_bytes;
    plan->heap_scoped_work = num_chunks > BLORP_PAR_STACK_CHUNKS;
    if (plan->heap_scoped_work) {
        plan->chunks = blorp_malloc_checked(num_chunks * chunk_bytes);
        plan->items = (blorp_WorkItem*)blorp_malloc_checked((num_chunks - 1) * sizeof(blorp_WorkItem));
    } else {
        plan->chunks = stack_chunks;
        plan->items = stack_items;
    }
    return true;
}

static inline void* __blorp_lparallel_chunk_at(blorp_LParallelPlan* plan, long index) {
    return (void*)((char*)plan->chunks + index * plan->chunk_bytes);
}

static void __blorp_lparallel_run(
    blorp_LParallelPlan* plan,
    blorp_LParallelChunkInit init,
    blorp_LParallelChunkWorker worker,
    void* ctx
) {
    plan->done_count = 0;
    pthread_mutex_init(&plan->done_lock, NULL);
    pthread_cond_init(&plan->done_cond, NULL);

    for (long c = 0; c < plan->num_chunks; c++) {
        long start = c * plan->chunk_size;
        long end = (c == plan->num_chunks - 1) ? plan->len : (c + 1) * plan->chunk_size;
        init(
            __blorp_lparallel_chunk_at(plan, c),
            c,
            start,
            end,
            &plan->done_lock,
            &plan->done_cond,
            &plan->done_count,
            ctx);
    }

    for (long c = 1; c < plan->num_chunks; c++) {
        void* chunk = __blorp_lparallel_chunk_at(plan, c);
        if (!__blorp_pool_submit_scoped(worker, chunk, &plan->items[c - 1])) {
            worker(chunk);
        }
    }

    worker(__blorp_lparallel_chunk_at(plan, 0));

    pthread_mutex_lock(&plan->done_lock);
    while (plan->done_count < plan->num_chunks) {
        pthread_cond_wait(&plan->done_cond, &plan->done_lock);
    }
    pthread_mutex_unlock(&plan->done_lock);
    pthread_mutex_destroy(&plan->done_lock);
    pthread_cond_destroy(&plan->done_cond);
}

static void __blorp_lparallel_plan_cleanup(blorp_LParallelPlan* plan) {
    if (plan->heap_scoped_work) {
        free(plan->items);
        free(plan->chunks);
    }
}

// --- Map Parallel ---

typedef struct {
    blorp_List* list;
    blorp_List* result;
    blorp_Closure* f;
    long start;
    long end;
    uint8_t result_value_encoding;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_LMapChunk;

typedef struct {
    blorp_List* list;
    blorp_List* result;
    blorp_Closure* f;
    uint8_t result_value_encoding;
} blorp_LMapInitCtx;

static void __blorp_lmap_init_chunk(
    void* raw_chunk,
    long index,
    long start,
    long end,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count,
    void* raw_ctx
) {
    (void)index;
    blorp_LMapInitCtx* ctx = (blorp_LMapInitCtx*)raw_ctx;
    blorp_LMapChunk* chunk = (blorp_LMapChunk*)raw_chunk;
    chunk->list = ctx->list;
    chunk->result = ctx->result;
    chunk->f = ctx->f;
    chunk->start = start;
    chunk->end = end;
    chunk->result_value_encoding = ctx->result_value_encoding;
    chunk->done_lock = done_lock;
    chunk->done_cond = done_cond;
    chunk->done_count = done_count;
}

static void __blorp_lmap_chunk_worker(void* arg) {
    blorp_LMapChunk* chunk = (blorp_LMapChunk*)arg;
    for (long i = chunk->start; i < chunk->end; i++) {
        blorp_list_store_callback_result(
            chunk->result,
            i,
            blorp_call1(chunk->f, blorp_list_get_unchecked(chunk->list, i)),
            chunk->result_value_encoding);
    }
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static blorp_List* __blorp_lmap_parallel_impl(
    blorp_List* list,
    blorp_Closure* f,
    long max_threads,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    if (!list || !f) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }
    long len = list->len;
    if (len == 0) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }

    blorp_List* result = blorp_list_new_result_layout(len, result_elem_is_rc, result_storage_mode, result_elem_size);
    result->len = len;

    blorp_LMapChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_LParallelPlan plan;
    if (!__blorp_lparallel_plan_init(&plan, len, max_threads, sizeof(blorp_LMapChunk), stack_chunks, stack_items)) {
        for (long i = 0; i < len; i++) {
            blorp_list_store_callback_result(result, i, blorp_call1(f, blorp_list_get_unchecked(list, i)), result_value_encoding);
        }
        return result;
    }

    blorp_LMapInitCtx init_ctx = { list, result, f, result_value_encoding };
    __blorp_lparallel_run(&plan, __blorp_lmap_init_chunk, __blorp_lmap_chunk_worker, &init_ctx);
    __blorp_lparallel_plan_cleanup(&plan);
    return result;
}

blorp_List* blorp_map_parallel(
    blorp_List* list,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lmap_parallel_impl(
        list,
        f,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

// --- Filter Parallel (two-phase: parallel predicate, sequential gather) ---

typedef struct {
    blorp_List* list;
    blorp_Closure* pred;
    int8_t* mask;
    blorp_List* result;
    long start;
    long end;
    long local_count;
    long output_start;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_LFilterChunk;

typedef struct {
    blorp_List* list;
    blorp_Closure* pred;
    int8_t* mask;
} blorp_LFilterInitCtx;

static void __blorp_lfilter_init_chunk(
    void* raw_chunk,
    long index,
    long start,
    long end,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count,
    void* raw_ctx
) {
    (void)index;
    blorp_LFilterInitCtx* ctx = (blorp_LFilterInitCtx*)raw_ctx;
    blorp_LFilterChunk* chunk = (blorp_LFilterChunk*)raw_chunk;
    chunk->list = ctx->list;
    chunk->pred = ctx->pred;
    chunk->mask = ctx->mask;
    chunk->result = NULL;
    chunk->start = start;
    chunk->end = end;
    chunk->local_count = 0;
    chunk->output_start = 0;
    chunk->done_lock = done_lock;
    chunk->done_cond = done_cond;
    chunk->done_count = done_count;
}

static void __blorp_lfilter_chunk_worker(void* arg) {
    blorp_LFilterChunk* chunk = (blorp_LFilterChunk*)arg;
    long count = 0;
    for (long i = chunk->start; i < chunk->end; i++) {
        long keep = (long)(intptr_t)blorp_call1(chunk->pred, blorp_list_get_unchecked(chunk->list, i));
        chunk->mask[i] = (int8_t)keep;
        if (keep) count++;
    }
    chunk->local_count = count;
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
    // NOTE: do NOT free — caller reads local_count
}

typedef struct {
    blorp_List* list;
    int8_t* mask;
    blorp_List* result;
    long* offsets;
} blorp_LFilterScatterInitCtx;

static void __blorp_lfilter_scatter_init_chunk(
    void* raw_chunk,
    long index,
    long start,
    long end,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count,
    void* raw_ctx
) {
    blorp_LFilterScatterInitCtx* ctx = (blorp_LFilterScatterInitCtx*)raw_ctx;
    blorp_LFilterChunk* chunk = (blorp_LFilterChunk*)raw_chunk;
    chunk->list = ctx->list;
    chunk->pred = NULL;
    chunk->mask = ctx->mask;
    chunk->result = ctx->result;
    chunk->start = start;
    chunk->end = end;
    chunk->local_count = 0;
    chunk->output_start = ctx->offsets[index];
    chunk->done_lock = done_lock;
    chunk->done_cond = done_cond;
    chunk->done_count = done_count;
}

static void __blorp_lfilter_scatter_worker(void* arg) {
    blorp_LFilterChunk* chunk = (blorp_LFilterChunk*)arg;
    blorp_List* list = chunk->list;
    long out = chunk->output_start;
    for (long i = chunk->start; i < chunk->end; i++) {
        if (chunk->mask[i]) {
            void* elem = blorp_list_get_unchecked(list, i);
            if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release && elem) blorp_retain(elem);
            blorp_list_store_raw(chunk->result, out++, elem);
        }
    }
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static blorp_List* __blorp_lfilter_parallel_impl(blorp_List* list, blorp_Closure* pred, long max_threads) {
    if (!list || !pred) return blorp_list_new(0);
    long len = list->len;
    if (len == 0) return blorp_list_new_layout(0, list->storage_mode, list->elem_size);

    blorp_LFilterChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_LParallelPlan plan;
    if (!__blorp_lparallel_plan_init(&plan, len, max_threads, sizeof(blorp_LFilterChunk), stack_chunks, stack_items)) {
        blorp_List* result = blorp_list_new_layout(len, list->storage_mode, list->elem_size);
        result->elem_release = list->elem_release;
        long count = 0;
        for (long i = 0; i < len; i++) {
            void* elem = blorp_list_get_unchecked(list, i);
            if ((long)(intptr_t)blorp_call1(pred, elem)) {
                if (list->storage_mode == BLORP_LIST_STORAGE_POINTER && list->elem_release && elem) blorp_retain(elem);
                blorp_list_store_raw(result, count++, elem);
            }
        }
        result->len = count;
        return result;
    }

    // Phase 1: parallel predicate evaluation
    int8_t* mask = (int8_t*)blorp_calloc_checked((size_t)len, sizeof(int8_t));
    blorp_LFilterInitCtx init_ctx = { list, pred, mask };
    __blorp_lparallel_run(&plan, __blorp_lfilter_init_chunk, __blorp_lfilter_chunk_worker, &init_ctx);

    // Phase 2: compute stable output offsets, then scatter kept values in parallel.
    long total_kept = 0;
    blorp_LFilterChunk* chunks = (blorp_LFilterChunk*)plan.chunks;
    long stack_offsets[BLORP_PAR_STACK_CHUNKS];
    long* offsets = plan.num_chunks > BLORP_PAR_STACK_CHUNKS
        ? (long*)blorp_malloc_checked((size_t)plan.num_chunks * sizeof(long))
        : stack_offsets;
    for (long c = 0; c < plan.num_chunks; c++) {
        offsets[c] = total_kept;
        total_kept += chunks[c].local_count;
    }

    blorp_List* result = blorp_list_new_layout(total_kept > 0 ? total_kept : 4, list->storage_mode, list->elem_size);
    result->elem_release = list->elem_release;
    if (total_kept > 0) {
        blorp_LFilterScatterInitCtx scatter_ctx = { list, mask, result, offsets };
        __blorp_lparallel_run(&plan, __blorp_lfilter_scatter_init_chunk, __blorp_lfilter_scatter_worker, &scatter_ctx);
    }
    result->len = total_kept;

    if (offsets != stack_offsets) free(offsets);
    free(mask);
    __blorp_lparallel_plan_cleanup(&plan);
    return result;
}

blorp_List* blorp_filter_parallel(blorp_List* list, blorp_Closure* pred) {
    return __blorp_lfilter_parallel_impl(list, pred, 0);
}

// --- Filter-map Parallel ---

typedef void (*blorp_LFilterMapApply)(blorp_List* out, blorp_Closure* f, void* elem, uint8_t result_value_encoding);

typedef struct {
    blorp_List* list;
    blorp_Closure* f;
    blorp_List* result;
    blorp_LFilterMapApply apply;
    long start;
    long end;
    int result_elem_is_rc;
    uint8_t result_storage_mode;
    int16_t result_elem_size;
    uint8_t result_value_encoding;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_LFilterMapChunk;

static inline void __blorp_lfilter_map_push(blorp_List* out, void* value, uint8_t result_value_encoding) {
    blorp_list_push_callback_result(out, value, result_value_encoding);
}

static void __blorp_lfilter_map_apply_boxed(blorp_List* out, blorp_Closure* f, void* elem, uint8_t result_value_encoding) {
    blorp_Option* opt = (blorp_Option*)blorp_call1(f, elem);
    if (opt && opt->tag == BLORP_TAG_SOME) {
        void* payload = opt->data.Some.field0;
        opt->release_mask = 0;
        __blorp_lfilter_map_push(out, payload, result_value_encoding);
    }
    if (opt) blorp_release(opt);
}

static void __blorp_lfilter_map_apply_nullable(blorp_List* out, blorp_Closure* f, void* elem, uint8_t result_value_encoding) {
    void* payload = blorp_call1(f, elem);
    if (payload) __blorp_lfilter_map_push(out, payload, result_value_encoding);
}

static void __blorp_lfilter_map_run_chunk(blorp_LFilterMapChunk* chunk) {
    long capacity = chunk->end - chunk->start;
    chunk->result = blorp_list_new_result_layout(
        capacity > 0 ? capacity : 1,
        chunk->result_elem_is_rc,
        chunk->result_storage_mode,
        chunk->result_elem_size);
    for (long i = chunk->start; i < chunk->end; i++) {
        chunk->apply(chunk->result, chunk->f, blorp_list_get_unchecked(chunk->list, i), chunk->result_value_encoding);
    }
}

static void __blorp_lfilter_map_chunk_worker(void* arg) {
    blorp_LFilterMapChunk* chunk = (blorp_LFilterMapChunk*)arg;
    __blorp_lfilter_map_run_chunk(chunk);
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static void __blorp_lfilter_map_init_chunk(
    blorp_LFilterMapChunk* chunk,
    blorp_List* list,
    blorp_Closure* f,
    blorp_LFilterMapApply apply,
    long start,
    long end,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count
) {
    chunk->list = list;
    chunk->f = f;
    chunk->result = NULL;
    chunk->apply = apply;
    chunk->start = start;
    chunk->end = end;
    chunk->result_elem_is_rc = result_elem_is_rc;
    chunk->result_storage_mode = result_storage_mode;
    chunk->result_elem_size = result_elem_size;
    chunk->result_value_encoding = result_value_encoding;
    chunk->done_lock = done_lock;
    chunk->done_cond = done_cond;
    chunk->done_count = done_count;
}

typedef struct {
    blorp_List* list;
    blorp_Closure* f;
    blorp_LFilterMapApply apply;
    int result_elem_is_rc;
    uint8_t result_storage_mode;
    int16_t result_elem_size;
    uint8_t result_value_encoding;
} blorp_LFilterMapInitCtx;

static void __blorp_lfilter_map_plan_init_chunk(
    void* raw_chunk,
    long index,
    long start,
    long end,
    pthread_mutex_t* done_lock,
    pthread_cond_t* done_cond,
    long* done_count,
    void* raw_ctx
) {
    (void)index;
    blorp_LFilterMapInitCtx* ctx = (blorp_LFilterMapInitCtx*)raw_ctx;
    __blorp_lfilter_map_init_chunk(
        (blorp_LFilterMapChunk*)raw_chunk,
        ctx->list,
        ctx->f,
        ctx->apply,
        start,
        end,
        ctx->result_elem_is_rc,
        ctx->result_storage_mode,
        ctx->result_elem_size,
        ctx->result_value_encoding,
        done_lock,
        done_cond,
        done_count);
}

static blorp_List* __blorp_lfilter_map_merge(
    blorp_LFilterMapChunk* chunks,
    long num_chunks,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size
) {
    long total_kept = 0;
    for (long c = 0; c < num_chunks; c++) {
        if (chunks[c].result) total_kept += chunks[c].result->len;
    }

    blorp_List* result = blorp_list_new_result_layout(
        total_kept > 0 ? total_kept : 1,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size);

    long out = 0;
    for (long c = 0; c < num_chunks; c++) {
        blorp_List* local = chunks[c].result;
        if (!local) continue;
        for (long i = 0; i < local->len; i++) {
            if (
                local->storage_mode == BLORP_LIST_STORAGE_INLINE &&
                result->storage_mode == BLORP_LIST_STORAGE_INLINE &&
                local->elem_size == result->elem_size
            ) {
                blorp_list_store_raw_copy(result, out++, (char*)local->data + i * local->elem_size);
            } else {
                blorp_list_store_raw(result, out++, blorp_list_get_unchecked(local, i));
            }
        }
        local->len = 0;
        blorp_release(local);
        chunks[c].result = NULL;
    }
    result->len = out;
    return result;
}

static blorp_List* __blorp_lfilter_map_parallel_impl(
    blorp_List* list,
    blorp_Closure* f,
    long max_threads,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding,
    blorp_LFilterMapApply apply
) {
    if (!list || !f) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }

    long len = list->len;
    if (len == 0) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }

    blorp_LFilterMapChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_LParallelPlan plan;
    if (!__blorp_lparallel_plan_init(&plan, len, max_threads, sizeof(blorp_LFilterMapChunk), stack_chunks, stack_items)) {
        blorp_LFilterMapChunk chunk;
        __blorp_lfilter_map_init_chunk(
            &chunk,
            list,
            f,
            apply,
            0,
            len,
            result_elem_is_rc,
            result_storage_mode,
            result_elem_size,
            result_value_encoding,
            NULL,
            NULL,
            NULL);
        __blorp_lfilter_map_run_chunk(&chunk);
        return chunk.result;
    }

    blorp_LFilterMapInitCtx init_ctx = {
        list,
        f,
        apply,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size,
        result_value_encoding
    };
    __blorp_lparallel_run(
        &plan,
        __blorp_lfilter_map_plan_init_chunk,
        __blorp_lfilter_map_chunk_worker,
        &init_ctx);

    blorp_List* result = __blorp_lfilter_map_merge(
        (blorp_LFilterMapChunk*)plan.chunks,
        plan.num_chunks,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size);

    __blorp_lparallel_plan_cleanup(&plan);
    return result;
}

blorp_List* blorp_filter_map_parallel(
    blorp_List* list,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lfilter_map_parallel_impl(
        list,
        f,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding,
        __blorp_lfilter_map_apply_boxed);
}

blorp_List* blorp_filter_map_parallel_nullable(
    blorp_List* list,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lfilter_map_parallel_impl(
        list,
        f,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding,
        __blorp_lfilter_map_apply_nullable);
}

#define BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(PUBLIC_SUFFIX, NAME, BOX) \
static void __blorp_lfilter_map_apply_##PUBLIC_SUFFIX(blorp_List* out, blorp_Closure* f, void* elem, uint8_t result_value_encoding) { \
    void* opt_box = blorp_call1(f, elem); \
    if (!opt_box) return; \
    blorp_StackOption_##NAME opt = blorp_unbox_struct(opt_box, blorp_StackOption_##NAME); \
    blorp_release(opt_box); \
    if (opt.tag == BLORP_TAG_SOME) { \
        __blorp_lfilter_map_push(out, BOX(opt.value), result_value_encoding); \
    } \
} \
blorp_List* blorp_filter_map_parallel_##PUBLIC_SUFFIX( \
    blorp_List* list, \
    blorp_Closure* f, \
    long result_elem_is_rc, \
    uint8_t result_storage_mode, \
    int16_t result_elem_size, \
    uint8_t result_value_encoding \
) { \
    return __blorp_lfilter_map_parallel_impl( \
        list, \
        f, \
        0, \
        result_elem_is_rc != 0, \
        result_storage_mode, \
        result_elem_size, \
        result_value_encoding, \
        __blorp_lfilter_map_apply_##PUBLIC_SUFFIX); \
}

BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(int, Int, blorp_stream_box_long)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(int8, Int8, blorp_stream_box_int8)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(int16, Int16, blorp_stream_box_int16)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(int32, Int32, blorp_stream_box_int32)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(int64, Int64, blorp_stream_box_long)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(uint8, UInt8, blorp_stream_box_uint8)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(uint16, UInt16, blorp_stream_box_uint16)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(uint32, UInt32, blorp_stream_box_uint32)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(uint64, UInt64, blorp_stream_box_uint64)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(float, Float, blorp_box_float)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(bool, Bool, blorp_stream_box_bool)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(char, Char, blorp_stream_box_int32)
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(f32, Float32, blorp_box_float32)
#ifdef __FLT16_MAX__
BLORP_DEFINE_LFILTER_MAP_STACK_OPTION(f16, Float16, blorp_box_float16)
#endif

#undef BLORP_DEFINE_LFILTER_MAP_STACK_OPTION

// --- Fold Parallel: stays sequential (requires associativity proof) ---

void* blorp_fold_parallel(blorp_List* list, void* init, blorp_Closure* f, int acc_is_rc) {
    if (!list || !f) return init;
    void* acc = init;
    for (long i = 0; i < list->len; i++) {
        void* elem = blorp_list_get(list, i);
        void* new_acc = blorp_call2(f, acc, elem);
        if (acc_is_rc && new_acc != acc && acc)
            blorp_release((blorp_Object*)acc);
        acc = new_acc;
    }
    return acc;
}

void* blorp_fold_parallel_ordered(blorp_List* list, void* init, blorp_Closure* f, int acc_is_rc) {
    return blorp_fold_parallel(list, init, f, acc_is_rc);
}

// --- Zip Parallel ---

typedef struct {
    blorp_List* list_a;
    blorp_List* list_b;
    blorp_List* result;
    blorp_Closure* f;
    long start;
    long end;
    uint8_t result_value_encoding;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_LZipChunk;

static void __blorp_lzip_chunk_worker(void* arg) {
    blorp_LZipChunk* chunk = (blorp_LZipChunk*)arg;
    for (long i = chunk->start; i < chunk->end; i++) {
        blorp_list_store_callback_result(
            chunk->result,
            i,
            blorp_call2(chunk->f, blorp_list_get(chunk->list_a, i), blorp_list_get(chunk->list_b, i)),
            chunk->result_value_encoding);
    }
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static blorp_List* __blorp_lzip_parallel_impl(
    blorp_List* list_a,
    blorp_List* list_b,
    blorp_Closure* f,
    long max_threads,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    if (!list_a || !list_b || !f) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }
    long len = list_a->len < list_b->len ? list_a->len : list_b->len;
    if (len == 0) {
        return blorp_list_new_result_layout(0, result_elem_is_rc, result_storage_mode, result_elem_size);
    }

    blorp_List* result = blorp_list_new_result_layout(len, result_elem_is_rc, result_storage_mode, result_elem_size);
    result->len = len;

    pthread_once(&__blorp_pool_once, __blorp_pool_init_default);
    long num_threads = max_threads > 0 ? max_threads : (__blorp_pool ? __blorp_pool->num_threads : 1);
    if (len < BLORP_LPAR_MIN_CHUNK * 2 || num_threads <= 1 || !__blorp_pool) {
        for (long i = 0; i < len; i++) {
            blorp_list_store_callback_result(
                result,
                i,
                blorp_call2(f, blorp_list_get(list_a, i), blorp_list_get(list_b, i)),
                result_value_encoding);
        }
        return result;
    }

    long num_chunks = num_threads;
    if (num_chunks > len / BLORP_LPAR_MIN_CHUNK) num_chunks = len / BLORP_LPAR_MIN_CHUNK;
    if (num_chunks < 2) num_chunks = 2;
    long chunk_size = len / num_chunks;

    pthread_mutex_t done_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t done_cond = PTHREAD_COND_INITIALIZER;
    long done_count = 0;

    blorp_LZipChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_LZipChunk* chunks = stack_chunks;
    blorp_WorkItem* items = stack_items;
    bool heap_scoped_work = num_chunks > BLORP_PAR_STACK_CHUNKS;
    if (heap_scoped_work) {
        chunks = (blorp_LZipChunk*)blorp_malloc_checked(num_chunks * sizeof(blorp_LZipChunk));
        items = (blorp_WorkItem*)blorp_malloc_checked((num_chunks - 1) * sizeof(blorp_WorkItem));
    }

    for (long c = 1; c < num_chunks; c++) {
        blorp_LZipChunk* chunk = &chunks[c];
        chunk->list_a = list_a;
        chunk->list_b = list_b;
        chunk->result = result;
        chunk->f = f;
        chunk->start = c * chunk_size;
        chunk->end = (c == num_chunks - 1) ? len : (c + 1) * chunk_size;
        chunk->result_value_encoding = result_value_encoding;
        chunk->done_lock = &done_lock;
        chunk->done_cond = &done_cond;
        chunk->done_count = &done_count;
        if (!__blorp_pool_submit_scoped(__blorp_lzip_chunk_worker, chunk, &items[c - 1])) {
            __blorp_lzip_chunk_worker(chunk);
        }
    }

    for (long i = 0; i < chunk_size; i++) {
        blorp_list_store_callback_result(
            result,
            i,
            blorp_call2(f, blorp_list_get(list_a, i), blorp_list_get(list_b, i)),
            result_value_encoding);
    }

    pthread_mutex_lock(&done_lock);
    while (done_count < num_chunks - 1) {
        pthread_cond_wait(&done_cond, &done_lock);
    }
    pthread_mutex_unlock(&done_lock);
    pthread_mutex_destroy(&done_lock);
    pthread_cond_destroy(&done_cond);

    if (heap_scoped_work) {
        free(items);
        free(chunks);
    }

    return result;
}

blorp_List* blorp_zip_parallel(
    blorp_List* list_a,
    blorp_List* list_b,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lzip_parallel_impl(
        list_a,
        list_b,
        f,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

// --- _with variants (pass thread count through) ---

blorp_List* blorp_map_parallel_with(
    blorp_List* list,
    blorp_Closure* f,
    long threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lmap_parallel_impl(
        list,
        f,
        threads,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

blorp_List* blorp_filter_parallel_with(blorp_List* list, blorp_Closure* pred, long threads) {
    return __blorp_lfilter_parallel_impl(list, pred, threads);
}

void* blorp_fold_parallel_with(blorp_List* list, void* init, blorp_Closure* f, long threads, int acc_is_rc) {
    (void)threads;  // Fold is inherently sequential
    return blorp_fold_parallel(list, init, f, acc_is_rc);
}

void* blorp_fold_parallel_ordered_with(blorp_List* list, void* init, blorp_Closure* f, long threads, int acc_is_rc) {
    (void)threads;
    return blorp_fold_parallel_ordered(list, init, f, acc_is_rc);
}

blorp_List* blorp_zip_parallel_with(
    blorp_List* list_a,
    blorp_List* list_b,
    blorp_Closure* f,
    long threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_lzip_parallel_impl(
        list_a,
        list_b,
        f,
        threads,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

// Sequential list HOFs are synthesized as Core IR so Perceus and COW analysis
// can see allocation, aliasing, transfer, and callback calls directly.
// (removed blorp_list_concat — now IR intrinsic)
// (removed blorp_list_reverse — now IR intrinsic)
// (removed blorp_list_tail — now IR intrinsic)
// (removed blorp_list_flatten — now IR intrinsic)
// (removed blorp_list_take — now IR intrinsic)

// List-spread pattern lowering still emits blorp_list_drop.
blorp_List* blorp_list_drop(blorp_List* list, long n) {
    if (!list) return blorp_list_new(0);
    long start = n < 0 ? 0 : n;
    if (start >= list->len) return blorp_list_new_layout(0, list->storage_mode, list->elem_size);
    long new_len = list->len - start;
    blorp_List* result = blorp_list_new_layout(new_len, list->storage_mode, list->elem_size);
    result->elem_release = list->elem_release;
    size_t stride = blorp_list_stride(list);
    memcpy(result->data, (char*)list->data + start * stride, new_len * stride);
    if (result->storage_mode == BLORP_LIST_STORAGE_POINTER && result->elem_release) {
        for (long i = 0; i < new_len; i++) {
            if (result->data[i]) blorp_retain(result->data[i]);
        }
    }
    result->len = new_len;
    return result;
}

// Returns List[(A, B)] - uses blorp_Tuple
blorp_Vector* blorp_vector_zip(blorp_Vector* a, blorp_Vector* b) {
    if (!a || !b) return blorp_vector_new(0);
    long len = a->len < b->len ? a->len : b->len;
    blorp_Vector* result = blorp_vector_new(len);
    for (long i = 0; i < len; i++) {
        blorp_Tuple* tuple = blorp_tuple_new(2, a->data[i], b->data[i]);
        long rc_mask = 0;
        if (a->elem_release && a->data[i]) { blorp_retain(a->data[i]); rc_mask |= 1; }
        if (b->elem_release && b->data[i]) { blorp_retain(b->data[i]); rc_mask |= 2; }
        if (rc_mask) blorp_tuple_set_rc(tuple, rc_mask);
        result->data[i] = (void*)tuple;
    }
    blorp_vector_init_elem_release(result, blorp_elem_release_fn);
    return result;
}
// (removed blorp_list_zip — now IR intrinsic)

// vector map: apply closure to each element, return new vector (no Option/COW overhead)
blorp_Vector* blorp_vector_map(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc) {
    if (!arr || !f) return blorp_vector_new(0);
    blorp_Vector* result = blorp_vector_new_noinit(arr->len);
    result->len = arr->len;
    if (result_elem_is_rc) {
        blorp_vector_init_elem_release(result, blorp_elem_release_fn);
    }
    for (long i = 0; i < arr->len; i++) {
        result->data[i] = blorp_call1(f, arr->data[i]);
    }
    return result;
}

// ============================================================================
// Vector Parallel Operations
// ============================================================================

// ---------------------------------------------------------------------------
// Parallel vector operations — thread pool chunked dispatch
// ---------------------------------------------------------------------------

// Minimum elements per chunk before parallelism kicks in
#define BLORP_VPAR_MIN_CHUNK 64

static blorp_Vector* blorp_vector_new_result_layout(
    long size,
    int result_elem_is_rc,
    uint8_t storage_mode,
    int16_t elem_size
) {
    if (size < 0) size = 0;
    switch (storage_mode) {
        case BLORP_VECTOR_STORAGE_F64:
            return blorp_vector_new_f64_noinit(size);
        case BLORP_VECTOR_STORAGE_F32:
            return blorp_vector_new_f32_noinit(size);
        case BLORP_VECTOR_STORAGE_I64:
            return blorp_vector_new_i64_noinit(size);
        case BLORP_VECTOR_STORAGE_INLINE:
            if (elem_size > 0) return blorp_vector_new_sized(size, elem_size);
            break;
        default:
            break;
    }

    blorp_Vector* result = blorp_vector_new_noinit(size);
    result->len = size;
    if (result_elem_is_rc) {
        blorp_vector_init_elem_release(result, blorp_elem_release_fn);
    }
    return result;
}

static void blorp_vector_release_callback_value(uint8_t result_value_encoding, void* value) {
    if (!value) return;
    if (result_value_encoding == BLORP_VECTOR_CALLBACK_BOXED_STRUCT) {
        blorp_release(value);
    }
}

static void blorp_vector_store_callback_result(
    blorp_Vector* result,
    long index,
    void* value,
    uint8_t result_value_encoding
) {
    if (!result || index < 0 || index >= result->capacity) {
        blorp_vector_release_callback_value(result_value_encoding, value);
        return;
    }

    if (result_value_encoding == BLORP_VECTOR_CALLBACK_BOXED_STRUCT
        && result->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        if (value) {
            memcpy(
                (char*)result->data + index * result->elem_size,
                (char*)value + sizeof(blorp_Object),
                result->elem_size);
            blorp_release(value);
        } else {
            memset((char*)result->data + index * result->elem_size, 0, result->elem_size);
        }
        return;
    }

    if (result_value_encoding == BLORP_VECTOR_CALLBACK_BOXED_FLOAT
        && result->storage_mode == BLORP_VECTOR_STORAGE_F64) {
        double unboxed = value ? blorp_unbox_float(value) : 0.0;
        blorp_vector_write_f64(result, index, unboxed);
        return;
    }

    if (result_value_encoding == BLORP_VECTOR_CALLBACK_BOXED_FLOAT32
        && result->storage_mode == BLORP_VECTOR_STORAGE_F32) {
        float unboxed = value ? blorp_unbox_float32(value) : 0.0f;
        blorp_vector_write_f32(result, index, unboxed);
        return;
    }

    if (result->storage_mode == BLORP_VECTOR_STORAGE_I64) {
        blorp_vector_write_i64(result, index, (long)(intptr_t)value);
        return;
    }

    if (result->storage_mode == BLORP_VECTOR_STORAGE_PACKED) {
        blorp_packed_set(result, index, (long)(intptr_t)value);
        return;
    }

    if (result->storage_mode == BLORP_VECTOR_STORAGE_INLINE) {
        void* slot = (char*)result->data + index * result->elem_size;
        if (result->elem_size <= (int16_t)sizeof(uintptr_t)) {
            uintptr_t bits = (uintptr_t)value;
            memcpy(slot, &bits, result->elem_size);
        } else if (value) {
            memcpy(slot, value, result->elem_size);
        } else {
            memset(slot, 0, result->elem_size);
        }
        return;
    }

    result->data[index] = value;
}

typedef struct {
    void* value;
    uint8_t release_after_call;
} blorp_VectorCallbackArg;

static blorp_VectorCallbackArg blorp_vector_callback_arg(blorp_Vector* arr, long index) {
    blorp_VectorCallbackArg arg = { NULL, 0 };
    if (!arr || index < 0 || index >= arr->len) return arg;

    switch (arr->storage_mode) {
        case BLORP_VECTOR_STORAGE_F64:
            arg.value = blorp_box_float(blorp_vector_read_f64(arr, index));
            return arg;
        case BLORP_VECTOR_STORAGE_F32:
            arg.value = blorp_box_float32(blorp_vector_read_f32(arr, index));
            return arg;
        case BLORP_VECTOR_STORAGE_I64:
            arg.value = (void*)(intptr_t)blorp_vector_read_i64(arr, index);
            return arg;
        case BLORP_VECTOR_STORAGE_PACKED:
            arg.value = (void*)(intptr_t)blorp_packed_get(arr, index);
            return arg;
        case BLORP_VECTOR_STORAGE_INLINE:
            if (arr->elem_size > 0) {
                arg.value = blorp_box_struct(
                    (char*)arr->data + index * arr->elem_size,
                    arr->elem_size);
                arg.release_after_call = 1;
                return arg;
            }
            break;
        default:
            break;
    }

    arg.value = arr->data[index];
    return arg;
}

static void blorp_vector_callback_arg_drop(blorp_VectorCallbackArg arg) {
    if (arg.release_after_call && arg.value) blorp_release(arg.value);
}

// Chunk descriptor for parallel map
typedef struct {
    blorp_Vector* arr;       // input
    blorp_Vector* result;    // output (pre-allocated, each chunk writes to its slice)
    blorp_Closure* f;        // closure to call
    long start;
    long end;
    int indexed;             // 1 = pass index as first arg
    uint8_t result_value_encoding;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_VMapChunk;

static void __blorp_vmap_chunk_worker(void* arg) {
    blorp_VMapChunk* chunk = (blorp_VMapChunk*)arg;
    for (long i = chunk->start; i < chunk->end; i++) {
        blorp_VectorCallbackArg elem = blorp_vector_callback_arg(chunk->arr, i);
        void* mapped;
        if (chunk->indexed) {
            mapped = blorp_call2(chunk->f, (void*)(intptr_t)i, elem.value);
        } else {
            mapped = blorp_call1(chunk->f, elem.value);
        }
        blorp_vector_callback_arg_drop(elem);
        blorp_vector_store_callback_result(
            chunk->result,
            i,
            mapped,
            chunk->result_value_encoding);
    }
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static blorp_Vector* __blorp_vmap_parallel_impl(
    blorp_Vector* arr,
    blorp_Closure* f,
    long max_threads,
    int indexed,
    int result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    if (!arr || !f) {
        return blorp_vector_new_result_layout(
            0,
            result_elem_is_rc,
            result_storage_mode,
            result_elem_size);
    }
    long len = arr->len;

    blorp_Vector* result = blorp_vector_new_result_layout(
        len,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size);

    // For small vectors or no pool, run sequentially
    pthread_once(&__blorp_pool_once, __blorp_pool_init_default);
    long num_threads = __blorp_pool ? __blorp_pool->num_threads : 1;
    if (max_threads > 0 && max_threads < num_threads) num_threads = max_threads;
    if (len < BLORP_VPAR_MIN_CHUNK * 2 || num_threads <= 1 || !__blorp_pool) {
        for (long i = 0; i < len; i++) {
            blorp_VectorCallbackArg elem = blorp_vector_callback_arg(arr, i);
            void* mapped;
            if (indexed) {
                mapped = blorp_call2(f, (void*)(intptr_t)i, elem.value);
            } else {
                mapped = blorp_call1(f, elem.value);
            }
            blorp_vector_callback_arg_drop(elem);
            blorp_vector_store_callback_result(
                result,
                i,
                mapped,
                result_value_encoding);
        }
        return result;
    }

    // Split into chunks and dispatch to thread pool
    long num_chunks = num_threads;
    if (num_chunks > len / BLORP_VPAR_MIN_CHUNK) num_chunks = len / BLORP_VPAR_MIN_CHUNK;
    if (num_chunks < 2) num_chunks = 2;
    long chunk_size = len / num_chunks;

    pthread_mutex_t done_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t done_cond = PTHREAD_COND_INITIALIZER;
    long done_count = 0;

    // Retain closure for each chunk (workers share it)
    for (long c = 0; c < num_chunks; c++) {
        blorp_retain(f);
    }

    blorp_VMapChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_VMapChunk* chunks = stack_chunks;
    blorp_WorkItem* items = stack_items;
    bool heap_scoped_work = num_chunks > BLORP_PAR_STACK_CHUNKS;
    if (heap_scoped_work) {
        chunks = (blorp_VMapChunk*)blorp_malloc_checked(num_chunks * sizeof(blorp_VMapChunk));
        items = (blorp_WorkItem*)blorp_malloc_checked((num_chunks - 1) * sizeof(blorp_WorkItem));
    }

    // Submit chunks 1..N to pool (chunk 0 runs on this thread)
    for (long c = 1; c < num_chunks; c++) {
        blorp_VMapChunk* chunk = &chunks[c];
        chunk->arr = arr;
        chunk->result = result;
        chunk->f = f;
        chunk->start = c * chunk_size;
        chunk->end = (c == num_chunks - 1) ? len : (c + 1) * chunk_size;
        chunk->indexed = indexed;
        chunk->result_value_encoding = result_value_encoding;
        chunk->done_lock = &done_lock;
        chunk->done_cond = &done_cond;
        chunk->done_count = &done_count;
        if (!__blorp_pool_submit_scoped(__blorp_vmap_chunk_worker, chunk, &items[c - 1])) {
            __blorp_vmap_chunk_worker(chunk);
        }
    }

    // Run chunk 0 on this thread
    long c0_end = chunk_size;
    for (long i = 0; i < c0_end; i++) {
        blorp_VectorCallbackArg elem = blorp_vector_callback_arg(arr, i);
        void* mapped;
        if (indexed) {
            mapped = blorp_call2(f, (void*)(intptr_t)i, elem.value);
        } else {
            mapped = blorp_call1(f, elem.value);
        }
        blorp_vector_callback_arg_drop(elem);
        blorp_vector_store_callback_result(
            result,
            i,
            mapped,
            result_value_encoding);
    }

    // Wait for all worker chunks to complete
    long workers = num_chunks - 1;
    pthread_mutex_lock(&done_lock);
    while (done_count < workers) {
        pthread_cond_wait(&done_cond, &done_lock);
    }
    pthread_mutex_unlock(&done_lock);
    pthread_mutex_destroy(&done_lock);
    pthread_cond_destroy(&done_cond);

    // Release closure refs (one per chunk)
    for (long c = 0; c < num_chunks; c++) {
        blorp_release(f);
    }
    if (heap_scoped_work) {
        free(items);
        free(chunks);
    }

    return result;
}

// Public API
blorp_Vector* blorp_vmap_parallel(
    blorp_Vector* arr,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vmap_parallel_impl(
        arr,
        f,
        0,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

blorp_Vector* blorp_vmap_indexed_parallel(
    blorp_Vector* arr,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vmap_parallel_impl(
        arr,
        f,
        0,
        1,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

blorp_Vector* blorp_vmap_parallel_with(
    blorp_Vector* arr,
    blorp_Closure* f,
    long threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vmap_parallel_impl(
        arr,
        f,
        threads,
        0,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

blorp_Vector* blorp_vmap_indexed_parallel_with(
    blorp_Vector* arr,
    blorp_Closure* f,
    long threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vmap_parallel_impl(
        arr,
        f,
        threads,
        1,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

// vfold_parallel: inherently sequential (accumulator dependency), runs single-threaded
void* blorp_vfold_parallel(blorp_Vector* arr, void* init, blorp_Closure* f, int acc_is_rc) {
    if (!arr || !f) return init;

    void* acc = init;
    for (long i = 0; i < arr->len; i++) {
        void* elem = arr->data[i];
        void* new_acc = blorp_call2(f, acc, elem);
        if (acc_is_rc && new_acc != acc && acc)
            blorp_release((blorp_Object*)acc);
        acc = new_acc;
    }
    return acc;
}

// vzip_parallel: parallel element-wise combine
typedef struct {
    blorp_Vector* arr_a;
    blorp_Vector* arr_b;
    blorp_Vector* result;
    blorp_Closure* f;
    long start;
    long end;
    uint8_t result_value_encoding;
    pthread_mutex_t* done_lock;
    pthread_cond_t* done_cond;
    long* done_count;
} blorp_VZipChunk;

static void __blorp_vzip_chunk_worker(void* arg) {
    blorp_VZipChunk* chunk = (blorp_VZipChunk*)arg;
    for (long i = chunk->start; i < chunk->end; i++) {
        blorp_VectorCallbackArg elem_a = blorp_vector_callback_arg(chunk->arr_a, i);
        blorp_VectorCallbackArg elem_b = blorp_vector_callback_arg(chunk->arr_b, i);
        void* mapped = blorp_call2(chunk->f, elem_a.value, elem_b.value);
        blorp_vector_callback_arg_drop(elem_a);
        blorp_vector_callback_arg_drop(elem_b);
        blorp_vector_store_callback_result(
            chunk->result,
            i,
            mapped,
            chunk->result_value_encoding);
    }
    pthread_mutex_lock(chunk->done_lock);
    (*chunk->done_count)++;
    pthread_cond_signal(chunk->done_cond);
    pthread_mutex_unlock(chunk->done_lock);
}

static blorp_Vector* __blorp_vzip_parallel_impl(
    blorp_Vector* arr_a,
    blorp_Vector* arr_b,
    blorp_Closure* f,
    long max_threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    if (!arr_a || !arr_b || !f) {
        return blorp_vector_new_result_layout(
            0,
            result_elem_is_rc != 0,
            result_storage_mode,
            result_elem_size);
    }
    long len = arr_a->len < arr_b->len ? arr_a->len : arr_b->len;

    blorp_Vector* result = blorp_vector_new_result_layout(
        len,
        result_elem_is_rc != 0,
        result_storage_mode,
        result_elem_size);

    pthread_once(&__blorp_pool_once, __blorp_pool_init_default);
    long num_threads = __blorp_pool ? __blorp_pool->num_threads : 1;
    if (max_threads > 0 && max_threads < num_threads) num_threads = max_threads;
    if (len < BLORP_VPAR_MIN_CHUNK * 2 || num_threads <= 1 || !__blorp_pool) {
        for (long i = 0; i < len; i++) {
            blorp_VectorCallbackArg elem_a = blorp_vector_callback_arg(arr_a, i);
            blorp_VectorCallbackArg elem_b = blorp_vector_callback_arg(arr_b, i);
            void* mapped = blorp_call2(f, elem_a.value, elem_b.value);
            blorp_vector_callback_arg_drop(elem_a);
            blorp_vector_callback_arg_drop(elem_b);
            blorp_vector_store_callback_result(
                result,
                i,
                mapped,
                result_value_encoding);
        }
        return result;
    }

    long num_chunks = num_threads;
    if (num_chunks > len / BLORP_VPAR_MIN_CHUNK) num_chunks = len / BLORP_VPAR_MIN_CHUNK;
    if (num_chunks < 2) num_chunks = 2;
    long chunk_size = len / num_chunks;

    pthread_mutex_t done_lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t done_cond = PTHREAD_COND_INITIALIZER;
    long done_count = 0;

    for (long c = 0; c < num_chunks; c++) blorp_retain(f);

    blorp_VZipChunk stack_chunks[BLORP_PAR_STACK_CHUNKS];
    blorp_WorkItem stack_items[BLORP_PAR_STACK_CHUNKS - 1];
    blorp_VZipChunk* chunks = stack_chunks;
    blorp_WorkItem* items = stack_items;
    bool heap_scoped_work = num_chunks > BLORP_PAR_STACK_CHUNKS;
    if (heap_scoped_work) {
        chunks = (blorp_VZipChunk*)blorp_malloc_checked(num_chunks * sizeof(blorp_VZipChunk));
        items = (blorp_WorkItem*)blorp_malloc_checked((num_chunks - 1) * sizeof(blorp_WorkItem));
    }

    for (long c = 1; c < num_chunks; c++) {
        blorp_VZipChunk* chunk = &chunks[c];
        chunk->arr_a = arr_a;
        chunk->arr_b = arr_b;
        chunk->result = result;
        chunk->f = f;
        chunk->start = c * chunk_size;
        chunk->end = (c == num_chunks - 1) ? len : (c + 1) * chunk_size;
        chunk->result_value_encoding = result_value_encoding;
        chunk->done_lock = &done_lock;
        chunk->done_cond = &done_cond;
        chunk->done_count = &done_count;
        if (!__blorp_pool_submit_scoped(__blorp_vzip_chunk_worker, chunk, &items[c - 1])) {
            __blorp_vzip_chunk_worker(chunk);
        }
    }

    for (long i = 0; i < chunk_size; i++) {
        blorp_VectorCallbackArg elem_a = blorp_vector_callback_arg(arr_a, i);
        blorp_VectorCallbackArg elem_b = blorp_vector_callback_arg(arr_b, i);
        void* mapped = blorp_call2(f, elem_a.value, elem_b.value);
        blorp_vector_callback_arg_drop(elem_a);
        blorp_vector_callback_arg_drop(elem_b);
        blorp_vector_store_callback_result(
            result,
            i,
            mapped,
            result_value_encoding);
    }

    long workers = num_chunks - 1;
    pthread_mutex_lock(&done_lock);
    while (done_count < workers) {
        pthread_cond_wait(&done_cond, &done_lock);
    }
    pthread_mutex_unlock(&done_lock);
    pthread_mutex_destroy(&done_lock);
    pthread_cond_destroy(&done_cond);

    for (long c = 0; c < num_chunks; c++) blorp_release(f);
    if (heap_scoped_work) {
        free(items);
        free(chunks);
    }

    return result;
}

blorp_Vector* blorp_vzip_parallel(
    blorp_Vector* arr_a,
    blorp_Vector* arr_b,
    blorp_Closure* f,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vzip_parallel_impl(
        arr_a,
        arr_b,
        f,
        0,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

void* blorp_vfold_parallel_with(blorp_Vector* arr, void* init, blorp_Closure* f, long threads, int acc_is_rc) {
    (void)threads;
    return blorp_vfold_parallel(arr, init, f, acc_is_rc);
}

blorp_Vector* blorp_vzip_parallel_with(
    blorp_Vector* arr_a,
    blorp_Vector* arr_b,
    blorp_Closure* f,
    long threads,
    long result_elem_is_rc,
    uint8_t result_storage_mode,
    int16_t result_elem_size,
    uint8_t result_value_encoding
) {
    return __blorp_vzip_parallel_impl(
        arr_a,
        arr_b,
        f,
        threads,
        result_elem_is_rc,
        result_storage_mode,
        result_elem_size,
        result_value_encoding);
}

// ============================================================================
// Math Operations
// ============================================================================

long blorp_abs(long x) { return x < 0 ? -x : x; }
long blorp_min(long a, long b) { return a < b ? a : b; }
long blorp_max(long a, long b) { return a > b ? a : b; }

double blorp_float_abs(double x) { return fabs(x); }
double blorp_float_min(double a, double b) { return fmin(a, b); }
double blorp_float_max(double a, double b) { return fmax(a, b); }

long blorp_round(double x) { return (long)round(x); }

// Float classification wrappers (C macros can't be called directly as functions)
long blorp_is_nan(double x) { return isnan(x) ? 1 : 0; }
long blorp_is_inf(double x) { return isinf(x) ? 1 : 0; }
long blorp_is_finite(double x) { return isfinite(x) ? 1 : 0; }

// Special float constants. Uses compiler intrinsics so the runtime
// is independent of [<math.h>]'s [INFINITY] / [NAN] macros.
double blorp_infinity(void) { return __builtin_inf(); }
double blorp_neg_infinity(void) { return -__builtin_inf(); }
double blorp_nan_value(void) { return __builtin_nan(""); }

// ============================================================================
// Random Number Generation
// ============================================================================

static _Thread_local unsigned int blorp_rng_seed = 1;

void blorp_seed_random(long seed) { blorp_rng_seed = (unsigned int)seed; }

long blorp_random_int(long min_val, long max_val) {
    if (min_val >= max_val) return min_val;
    long range = max_val - min_val;
    long limit = RAND_MAX - (RAND_MAX % range);
    long r;
    do {
        r = (long)rand_r(&blorp_rng_seed);
    } while (r >= limit);
    return min_val + (r % range);
}

double blorp_random_float(void) {
    return (double)rand_r(&blorp_rng_seed) / ((double)RAND_MAX + 1.0);
}

// ============================================================================
// ============================================================================

blorp_Bytes* blorp_crypto_random_bytes(long n) {
    if (n < 0) n = 0;
    blorp_Bytes* b = blorp_bytes_new(n);
    if (n > 0) {
#if defined(__APPLE__)
        arc4random_buf(b->data, (size_t)n);
#elif defined(__linux__)
        ssize_t r = getrandom(b->data, (size_t)n, 0);
        if (r != (ssize_t)n) {
            // fallback to /dev/urandom
            FILE* f = fopen("/dev/urandom", "rb");
            if (f) {
                fread(b->data, 1, (size_t)n, f);
                fclose(f);
            } else {
                fprintf(stderr, "blorp: FATAL: no random source available\n");
                exit(1);
            }
        }
#else
        FILE* f = fopen("/dev/urandom", "rb");
        if (f) {
            fread(b->data, 1, (size_t)n, f);
            fclose(f);
        } else {
            fprintf(stderr, "blorp: FATAL: no random source available\n");
            exit(1);
        }
#endif
    }
    return b;
}

// ============================================================================
// Timing
// ============================================================================

#include <time.h>

long blorp_now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000L + ts.tv_nsec / 1000L;
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#endif
long blorp_black_box_int(long value) {
#if defined(__GNUC__) || defined(__clang__)
    __asm__ volatile("" : "+r"(value) : : "memory");
    return value;
#else
    volatile long sink = value;
    return sink;
#endif
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#endif
double blorp_black_box_float(double value) {
#if defined(__GNUC__) || defined(__clang__)
    __asm__ volatile("" : "+m"(value) : : "memory");
    return value;
#else
    volatile double sink = value;
    return sink;
#endif
}

// ============================================================================
// Date/Time (wall-clock, POSIX microseconds)
// ============================================================================

// Wall-clock time in microseconds since POSIX epoch
long blorp_time_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec * 1000000L + ts.tv_nsec / 1000L;
}

// Helper: convert microseconds to struct tm (UTC)
static struct tm blorp_us_to_tm(long us) {
    time_t secs = us / 1000000L;
    struct tm result;
    gmtime_r(&secs, &result);
    return result;
}

long blorp_time_to_year(long us)    { return blorp_us_to_tm(us).tm_year + 1900; }
long blorp_time_to_month(long us)   { return blorp_us_to_tm(us).tm_mon + 1; }
long blorp_time_to_day(long us)     { return blorp_us_to_tm(us).tm_mday; }
long blorp_time_to_hour(long us)    { return blorp_us_to_tm(us).tm_hour; }
long blorp_time_to_minute(long us)  { return blorp_us_to_tm(us).tm_min; }
long blorp_time_to_second(long us)  { return blorp_us_to_tm(us).tm_sec; }
long blorp_time_to_weekday(long us) { return blorp_us_to_tm(us).tm_wday; }

// Construct POSIX microseconds from calendar parts (UTC)
long blorp_time_from_parts(long year, long month, long day, long hour, long minute, long second) {
    struct tm t = {0};
    t.tm_year = (int)(year - 1900);
    t.tm_mon = (int)(month - 1);
    t.tm_mday = (int)day;
    t.tm_hour = (int)hour;
    t.tm_min = (int)minute;
    t.tm_sec = (int)second;
    time_t secs = timegm(&t);
    return (long)secs * 1000000L;
}

// Format microsecond timestamp using strftime (256-byte output limit)
blorp_String* blorp_time_format(long us, const blorp_String* fmt) {
    struct tm t = blorp_us_to_tm(us);
    char* cfmt = (char*)blorp_malloc_checked(fmt->len + 1);
    memcpy(cfmt, fmt->data, fmt->len);
    cfmt[fmt->len] = '\0';

    char buf[256];
    size_t len = strftime(buf, sizeof(buf), cfmt, &t);
    free(cfmt);

    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = (long)len;
    result->capacity = (long)len;
    memcpy(result->data, buf, len);
    result->data[len] = '\0';
    return result;
}

// Parse a date string using strptime, returns stack Option[Int] (microseconds)
blorp_StackOption_Int blorp_time_parse(const blorp_String* s, const blorp_String* fmt) {
    char* cs = (char*)blorp_malloc_checked(s->len + 1);
    memcpy(cs, s->data, s->len);
    cs[s->len] = '\0';

    char* cfmt = (char*)blorp_malloc_checked(fmt->len + 1);
    memcpy(cfmt, fmt->data, fmt->len);
    cfmt[fmt->len] = '\0';

    struct tm t = {0};
    char* result = strptime(cs, cfmt, &t);

    if (!result || *result != '\0') {
        free(cs);
        free(cfmt);
        return blorp_stack_option_int_none();
    }
    free(cs);
    free(cfmt);

    time_t secs = timegm(&t);
    return blorp_stack_option_int_some(secs * 1000000L);
}

// from_iso: Parse ISO 8601 / RFC 3339 date string to POSIX microseconds.
blorp_StackOption_Int blorp_time_from_iso(const blorp_String* s) {
    if (!s || s->len < 10) return blorp_stack_option_int_none();
    const char* p = s->data;
    long len = s->len;

    int year = 0, month = 0, day = 0;
    if (p[4] != '-' || p[7] != '-') return blorp_stack_option_int_none();
    for (int i = 0; i < 4; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); year = year * 10 + (p[i] - '0'); }
    for (int i = 5; i < 7; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); month = month * 10 + (p[i] - '0'); }
    for (int i = 8; i < 10; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); day = day * 10 + (p[i] - '0'); }
    if (month < 1 || month > 12 || day < 1 || day > 31) return blorp_stack_option_int_none();

    int hour = 0, minute = 0, second = 0;
    long frac_us = 0, offset_us = 0;

    if (len > 10) {
        if (p[10] != 'T' && p[10] != 't') return blorp_stack_option_int_none();
        if (len < 19) return blorp_stack_option_int_none();
        if (p[13] != ':' || p[16] != ':') return blorp_stack_option_int_none();
        for (int i = 11; i < 13; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); hour = hour * 10 + (p[i] - '0'); }
        for (int i = 14; i < 16; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); minute = minute * 10 + (p[i] - '0'); }
        for (int i = 17; i < 19; i++) { if (p[i] < '0' || p[i] > '9') return blorp_stack_option_int_none(); second = second * 10 + (p[i] - '0'); }
        if (hour > 23 || minute > 59 || second > 59) return blorp_stack_option_int_none();

        long pos = 19;
        if (pos < len && p[pos] == '.') {
            pos++;
            long frac_digits = 0, frac_val = 0;
            while (pos < len && p[pos] >= '0' && p[pos] <= '9' && frac_digits < 6) {
                frac_val = frac_val * 10 + (p[pos] - '0'); frac_digits++; pos++;
            }
            while (pos < len && p[pos] >= '0' && p[pos] <= '9') pos++;
            while (frac_digits < 6) { frac_val *= 10; frac_digits++; }
            frac_us = frac_val;
        }
        if (pos < len) {
            if (p[pos] == 'Z' || p[pos] == 'z') { /* UTC */ }
            else if (p[pos] == '+' || p[pos] == '-') {
                int sign = (p[pos] == '+') ? 1 : -1;
                pos++;
                if (pos + 5 > len || p[pos+2] != ':') return blorp_stack_option_int_none();
                int oh = (p[pos] - '0') * 10 + (p[pos+1] - '0');
                int om = (p[pos+3] - '0') * 10 + (p[pos+4] - '0');
                offset_us = (long)sign * ((long)oh * 3600000000L + (long)om * 60000000L);
            }
        }
    }

    struct tm t = {0};
    t.tm_year = year - 1900; t.tm_mon = month - 1; t.tm_mday = day;
    t.tm_hour = hour; t.tm_min = minute; t.tm_sec = second;
    time_t secs = timegm(&t);
    if (secs == (time_t)-1 && year != 1969) return blorp_stack_option_int_none();
    long us = secs * 1000000L + frac_us - offset_us;
    return blorp_stack_option_int_some(us);
}


// ============================================================================
// Tuple Support
// ============================================================================

// blorp_Tuple typedef is above (in Dict section) as forward declaration

blorp_Tuple* blorp_tuple_new(long arity, ...) {
    blorp_Tuple* t = (blorp_Tuple*)blorp_alloc(blorp_checked_add(sizeof(blorp_Tuple), blorp_checked_mul(arity, sizeof(void*))));
    BLORP_TAG(t, "Tuple");
    t->arity = arity;
    t->release_mask = 0;  // No element ownership by default
    va_list args;
    va_start(args, arity);
    for (long i = 0; i < arity; i++) t->elem[i] = va_arg(args, void*);
    va_end(args);
    return t;
}

// ============================================================================
// Stream[T] — Lazy pull-based sequences
// ============================================================================

// Stream type: wraps a pull function + opaque state
typedef struct blorp_Stream {
    blorp_Object header;
    bool (*pull)(struct blorp_Stream* self, void** out);
    void* state;
    void (*state_cleanup)(struct blorp_Stream* self);
    bool elem_is_rc;  // True if elements are refcounted (String, List, etc.)
    bool elem_is_owned;  // True if pull transfers an owned element.
} blorp_Stream;

static void blorp_stream_destroy(void* obj) {
    blorp_Stream* s = (blorp_Stream*)obj;
    if (s->state_cleanup) s->state_cleanup(s);
}

// --- State types for different stream kinds ---

typedef struct { blorp_List* list; long idx; } StreamListState;
typedef struct { long current; long end; } StreamRangeState;
typedef struct { blorp_Stream* inner; blorp_Closure* func; } StreamMapState;
typedef struct { blorp_Stream* inner; blorp_Closure* pred; } StreamFilterState;
typedef struct { blorp_Stream* inner; long remaining; } StreamTakeState;
typedef struct { blorp_Stream* inner; long skipped; long n; } StreamDropState;
typedef struct { blorp_Stream* inner; blorp_Closure* pred; bool done; } StreamTakeWhileState;
typedef struct { blorp_Stream* inner; long idx; } StreamEnumState;
typedef struct { blorp_Stream* inner; blorp_Closure* func; } StreamFilterMapState;
typedef struct { void* value; bool is_rc; } StreamRepeatState;
typedef struct { void* state_val; blorp_Closure* func; bool done; bool state_is_rc; } StreamUnfoldState;
typedef struct { FILE* fp; char* buf; size_t buf_size; } StreamLinesState;

// --- Helper: allocate a stream ---
static blorp_Stream* blorp_stream_new(void) {
    blorp_Stream* s = (blorp_Stream*)blorp_alloc(sizeof(blorp_Stream));
    BLORP_SET_DESTRUCTOR(s, blorp_stream_destroy);
    s->state = NULL;
    s->state_cleanup = NULL;
    s->elem_is_rc = false;
    s->elem_is_owned = false;
    return s;
}

static inline void blorp_stream_release_pulled_if_owned(blorp_Stream* stream, void* value) {
    if (stream && stream->elem_is_owned && stream->elem_is_rc && value) {
        blorp_release(value);
    }
}

// --- from_list ---
static bool stream_list_pull(blorp_Stream* self, void** out) {
    StreamListState* st = (StreamListState*)self->state;
    if (st->idx >= st->list->len) return false;
    *out = blorp_list_get(st->list, st->idx++);
    return true;
}
static void stream_list_cleanup(blorp_Stream* self) {
    StreamListState* st = (StreamListState*)self->state;
    if (st->list) blorp_release((blorp_Object*)st->list);
    free(st);
}
blorp_Stream* blorp_stream_from_list(blorp_List* list) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = list && list->elem_release != NULL;
    StreamListState* st = malloc(sizeof(StreamListState));
    st->list = list;
    if (list) blorp_retain((blorp_Object*)list);
    st->idx = 0;
    s->state = st;
    s->pull = stream_list_pull;
    s->state_cleanup = stream_list_cleanup;
    return s;
}

// --- from_range ---
static bool stream_range_pull(blorp_Stream* self, void** out) {
    StreamRangeState* st = (StreamRangeState*)self->state;
    if (st->current >= st->end) return false;
    *out = (void*)(long)st->current++;
    return true;
}
static void stream_range_cleanup(blorp_Stream* self) {
    free(self->state);
}
blorp_Stream* blorp_stream_from_range(long start, long end) {
    blorp_Stream* s = blorp_stream_new();
    StreamRangeState* st = malloc(sizeof(StreamRangeState));
    st->current = start;
    st->end = end;
    s->state = st;
    s->pull = stream_range_pull;
    s->state_cleanup = stream_range_cleanup;
    return s;
}

// --- repeat ---
static bool stream_repeat_pull(blorp_Stream* self, void** out) {
    StreamRepeatState* st = (StreamRepeatState*)self->state;
    *out = st->value;
    return true;
}
static void stream_repeat_cleanup(blorp_Stream* self) {
    StreamRepeatState* st = (StreamRepeatState*)self->state;
    if (st->is_rc && st->value) blorp_release(st->value);
    free(st);
}
blorp_Stream* blorp_stream_repeat(void* value) {
    blorp_Stream* s = blorp_stream_new();
    StreamRepeatState* st = malloc(sizeof(StreamRepeatState));
    st->value = value;
    st->is_rc = false;  // Caller manages RC if needed
    s->state = st;
    s->pull = stream_repeat_pull;
    s->state_cleanup = stream_repeat_cleanup;
    return s;
}

// --- unfold ---
static bool stream_unfold_pull(blorp_Stream* self, void** out) {
    StreamUnfoldState* st = (StreamUnfoldState*)self->state;
    if (st->done) return false;
    // Call f(state) -> Option[(T, S)]
    blorp_Option* opt = (blorp_Option*)blorp_call1(st->func, st->state_val);
    if (!opt || opt->tag != BLORP_TAG_SOME) {
        if (opt) blorp_release(opt);
        st->done = true;
        return false;
    }
    // Extract (value, new_state) from the tuple in Some
    blorp_Tuple* pair = (blorp_Tuple*)opt->data.Some.field0;
    *out = pair->elem[0];
    void* new_state = pair->elem[1];
    if (st->state_is_rc && new_state) blorp_retain(new_state);
    if (st->state_is_rc && st->state_val) blorp_release(st->state_val);
    st->state_val = new_state;
    opt->release_mask = 0;  // we took ownership of field0
    blorp_release(opt);
    return true;
}
static void stream_unfold_cleanup(blorp_Stream* self) {
    StreamUnfoldState* st = (StreamUnfoldState*)self->state;
    if (st->func) blorp_release((blorp_Object*)st->func);
    if (st->state_is_rc && st->state_val) blorp_release(st->state_val);
    free(st);
}
blorp_Stream* blorp_stream_unfold(void* seed, blorp_Closure* func) {
    blorp_Stream* s = blorp_stream_new();
    StreamUnfoldState* st = malloc(sizeof(StreamUnfoldState));
    st->state_val = seed;
    st->func = func;
    if (func) blorp_retain((blorp_Object*)func);
    st->done = false;
    st->state_is_rc = false;
    s->state = st;
    s->pull = stream_unfold_pull;
    s->state_cleanup = stream_unfold_cleanup;
    return s;
}

// --- empty ---
static bool stream_empty_pull(blorp_Stream* self, void** out) {
    (void)self; (void)out;
    return false;
}
blorp_Stream* blorp_stream_empty(void) {
    blorp_Stream* s = blorp_stream_new();
    s->pull = stream_empty_pull;
    return s;
}

// --- map ---
static bool stream_map_pull(blorp_Stream* self, void** out) {
    StreamMapState* st = (StreamMapState*)self->state;
    void* val;
    if (!st->inner->pull(st->inner, &val)) return false;
    void* mapped = blorp_call1(st->func, val);
    blorp_stream_release_pulled_if_owned(st->inner, val);
    *out = mapped;
    return true;
}
static void stream_map_cleanup(blorp_Stream* self) {
    StreamMapState* st = (StreamMapState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    if (st->func) blorp_release((blorp_Object*)st->func);
    free(st);
}
blorp_Stream* blorp_stream_map(blorp_Stream* inner, blorp_Closure* func) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    StreamMapState* st = malloc(sizeof(StreamMapState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->func = func;
    if (func) blorp_retain((blorp_Object*)func);
    s->state = st;
    s->pull = stream_map_pull;
    s->state_cleanup = stream_map_cleanup;
    return s;
}

// --- filter ---
static bool stream_filter_pull(blorp_Stream* self, void** out) {
    StreamFilterState* st = (StreamFilterState*)self->state;
    void* val;
    while (st->inner->pull(st->inner, &val)) {
        if ((long)blorp_call1(st->pred, val)) {
            *out = val;
            return true;
        }
        blorp_stream_release_pulled_if_owned(st->inner, val);
    }
    return false;
}
static void stream_filter_cleanup(blorp_Stream* self) {
    StreamFilterState* st = (StreamFilterState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    if (st->pred) blorp_release((blorp_Object*)st->pred);
    free(st);
}
blorp_Stream* blorp_stream_filter(blorp_Stream* inner, blorp_Closure* pred) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    s->elem_is_owned = inner->elem_is_owned;
    StreamFilterState* st = malloc(sizeof(StreamFilterState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->pred = pred;
    if (pred) blorp_retain((blorp_Object*)pred);
    s->state = st;
    s->pull = stream_filter_pull;
    s->state_cleanup = stream_filter_cleanup;
    return s;
}

// --- filter_map ---
static bool stream_filter_map_pull(blorp_Stream* self, void** out) {
    StreamFilterMapState* st = (StreamFilterMapState*)self->state;
    void* val;
    while (st->inner->pull(st->inner, &val)) {
        blorp_Option* opt = (blorp_Option*)blorp_call1(st->func, val);
        blorp_stream_release_pulled_if_owned(st->inner, val);
        if (opt && opt->tag == BLORP_TAG_SOME) {
            *out = opt->data.Some.field0;
            opt->release_mask = 0;
            blorp_release(opt);
            return true;
        }
        if (opt) blorp_release(opt);
    }
    return false;
}
blorp_Stream* blorp_stream_filter_map(blorp_Stream* inner, blorp_Closure* func) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    StreamFilterMapState* st = malloc(sizeof(StreamFilterMapState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->func = func;
    if (func) blorp_retain((blorp_Object*)func);
    s->state = st;
    s->pull = stream_filter_map_pull;
    s->state_cleanup = stream_map_cleanup;  // same layout as map
    return s;
}

#define BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(PUBLIC_SUFFIX, NAME, BOX) \
static bool stream_filter_map_pull_##PUBLIC_SUFFIX(blorp_Stream* self, void** out) { \
    StreamFilterMapState* st = (StreamFilterMapState*)self->state; \
    void* val; \
    while (st->inner->pull(st->inner, &val)) { \
        void* opt_box = blorp_call1(st->func, val); \
        blorp_stream_release_pulled_if_owned(st->inner, val); \
        if (!opt_box) continue; \
        blorp_StackOption_##NAME opt = blorp_unbox_struct(opt_box, blorp_StackOption_##NAME); \
        blorp_release(opt_box); \
        if (opt.tag == BLORP_TAG_SOME) { \
            *out = BOX(opt.value); \
            return true; \
        } \
    } \
    return false; \
} \
blorp_Stream* blorp_stream_filter_map_##PUBLIC_SUFFIX(blorp_Stream* inner, blorp_Closure* func) { \
    blorp_Stream* s = blorp_stream_new(); \
    s->elem_is_rc = false; \
    s->elem_is_owned = false; \
    StreamFilterMapState* st = malloc(sizeof(StreamFilterMapState)); \
    st->inner = inner; \
    if (inner) blorp_retain((blorp_Object*)inner); \
    st->func = func; \
    if (func) blorp_retain((blorp_Object*)func); \
    s->state = st; \
    s->pull = stream_filter_map_pull_##PUBLIC_SUFFIX; \
    s->state_cleanup = stream_map_cleanup; \
    return s; \
}

BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(int, Int, blorp_stream_box_long)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(int8, Int8, blorp_stream_box_int8)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(int16, Int16, blorp_stream_box_int16)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(int32, Int32, blorp_stream_box_int32)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(int64, Int64, blorp_stream_box_long)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(uint8, UInt8, blorp_stream_box_uint8)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(uint16, UInt16, blorp_stream_box_uint16)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(uint32, UInt32, blorp_stream_box_uint32)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(uint64, UInt64, blorp_stream_box_uint64)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(float, Float, blorp_box_float)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(bool, Bool, blorp_stream_box_bool)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(char, Char, blorp_stream_box_int32)
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(f32, Float32, blorp_box_float32)
#ifdef __FLT16_MAX__
BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION(f16, Float16, blorp_box_float16)
#endif

#undef BLORP_DEFINE_STREAM_FILTER_MAP_STACK_OPTION

static bool stream_filter_map_pull_nullable(blorp_Stream* self, void** out) {
    StreamFilterMapState* st = (StreamFilterMapState*)self->state;
    void* val;
    while (st->inner->pull(st->inner, &val)) {
        void* opt = blorp_call1(st->func, val);
        blorp_stream_release_pulled_if_owned(st->inner, val);
        if (opt) {
            *out = opt;
            return true;
        }
    }
    return false;
}
blorp_Stream* blorp_stream_filter_map_nullable(blorp_Stream* inner, blorp_Closure* func) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = true;
    s->elem_is_owned = true;
    StreamFilterMapState* st = malloc(sizeof(StreamFilterMapState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->func = func;
    if (func) blorp_retain((blorp_Object*)func);
    s->state = st;
    s->pull = stream_filter_map_pull_nullable;
    s->state_cleanup = stream_map_cleanup;
    return s;
}

// --- take ---
static bool stream_take_pull(blorp_Stream* self, void** out) {
    StreamTakeState* st = (StreamTakeState*)self->state;
    if (st->remaining <= 0) return false;
    st->remaining--;
    return st->inner->pull(st->inner, out);
}
static void stream_take_cleanup(blorp_Stream* self) {
    StreamTakeState* st = (StreamTakeState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    free(st);
}
blorp_Stream* blorp_stream_take(blorp_Stream* inner, long n) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    s->elem_is_owned = inner->elem_is_owned;
    StreamTakeState* st = malloc(sizeof(StreamTakeState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->remaining = n;
    s->state = st;
    s->pull = stream_take_pull;
    s->state_cleanup = stream_take_cleanup;
    return s;
}

// --- drop ---
static bool stream_drop_pull(blorp_Stream* self, void** out) {
    StreamDropState* st = (StreamDropState*)self->state;
    while (st->skipped < st->n) {
        void* discard;
        if (!st->inner->pull(st->inner, &discard)) return false;
        blorp_stream_release_pulled_if_owned(st->inner, discard);
        st->skipped++;
    }
    return st->inner->pull(st->inner, out);
}
static void stream_drop_cleanup(blorp_Stream* self) {
    StreamDropState* st = (StreamDropState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    free(st);
}
blorp_Stream* blorp_stream_drop(blorp_Stream* inner, long n) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    s->elem_is_owned = inner->elem_is_owned;
    StreamDropState* st = malloc(sizeof(StreamDropState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->skipped = 0;
    st->n = n;
    s->state = st;
    s->pull = stream_drop_pull;
    s->state_cleanup = stream_drop_cleanup;
    return s;
}

// --- take_while ---
static bool stream_take_while_pull(blorp_Stream* self, void** out) {
    StreamTakeWhileState* st = (StreamTakeWhileState*)self->state;
    if (st->done) return false;
    void* val;
    if (!st->inner->pull(st->inner, &val)) { st->done = true; return false; }
    if ((long)blorp_call1(st->pred, val)) {
        *out = val;
        return true;
    }
    blorp_stream_release_pulled_if_owned(st->inner, val);
    st->done = true;
    return false;
}
static void stream_take_while_cleanup(blorp_Stream* self) {
    StreamTakeWhileState* st = (StreamTakeWhileState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    if (st->pred) blorp_release((blorp_Object*)st->pred);
    free(st);
}
blorp_Stream* blorp_stream_take_while(blorp_Stream* inner, blorp_Closure* pred) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = inner->elem_is_rc;
    s->elem_is_owned = inner->elem_is_owned;
    StreamTakeWhileState* st = malloc(sizeof(StreamTakeWhileState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->pred = pred;
    if (pred) blorp_retain((blorp_Object*)pred);
    st->done = false;
    s->state = st;
    s->pull = stream_take_while_pull;
    s->state_cleanup = stream_take_while_cleanup;
    return s;
}

// --- enumerate ---
static bool stream_enum_pull(blorp_Stream* self, void** out) {
    StreamEnumState* st = (StreamEnumState*)self->state;
    void* val;
    if (!st->inner->pull(st->inner, &val)) return false;
    blorp_Tuple* t = blorp_tuple_new(2, (void*)(long)st->idx, val);
    if (st->inner->elem_is_rc && val) {
        if (!st->inner->elem_is_owned) blorp_retain(val);
        blorp_tuple_set_rc(t, 2UL);
    }
    st->idx++;
    *out = t;
    return true;
}
static void stream_enum_cleanup(blorp_Stream* self) {
    StreamEnumState* st = (StreamEnumState*)self->state;
    if (st->inner) blorp_release((blorp_Object*)st->inner);
    free(st);
}
blorp_Stream* blorp_stream_enumerate(blorp_Stream* inner) {
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = true;
    s->elem_is_owned = true;
    StreamEnumState* st = malloc(sizeof(StreamEnumState));
    st->inner = inner;
    if (inner) blorp_retain((blorp_Object*)inner);
    st->idx = 0;
    s->state = st;
    s->pull = stream_enum_pull;
    s->state_cleanup = stream_enum_cleanup;
    return s;
}

// --- Terminal: collect ---
blorp_List* blorp_stream_collect(blorp_Stream* stream) {
    if (!stream) return blorp_list_new(0);
    blorp_List* result = blorp_list_new(16);
    if (stream->elem_is_rc) {
        extern void blorp_elem_release_fn(void*);
        result->elem_release = blorp_elem_release_fn;
    }
    void* val;
    while (stream->pull(stream, &val)) {
        if (stream->elem_is_rc && stream->elem_is_owned) {
            result = blorp_list_append_owned(result, val);
        } else {
            result = blorp_list_append(result, val);
        }
    }
    return result;
}

// --- Terminal: fold ---
void* blorp_stream_fold(blorp_Stream* stream, void* init, blorp_Closure* func, bool acc_is_rc) {
    if (!stream || !func) return init;
    void* acc = init;
    void* val;
    while (stream->pull(stream, &val)) {
        void* new_acc = ((void* (*)(void*, void*, void*))(func->func))(func->env, acc, val);
        blorp_stream_release_pulled_if_owned(stream, val);
        if (acc_is_rc && new_acc != acc && acc) blorp_release(acc);
        acc = new_acc;
    }
    return acc;
}

// --- Terminal: count ---
long blorp_stream_count(blorp_Stream* stream) {
    if (!stream) return 0;
    long n = 0;
    void* val;
    while (stream->pull(stream, &val)) {
        n++;
        blorp_stream_release_pulled_if_owned(stream, val);
    }
    return n;
}

// --- Terminal: for_each ---
void blorp_stream_for_each(blorp_Stream* stream, blorp_Closure* func) {
    if (!stream || !func) return;
    void* val;
    while (stream->pull(stream, &val)) {
        blorp_call1(func, val);
        blorp_stream_release_pulled_if_owned(stream, val);
    }
}

// --- Terminal: find ---
bool blorp_stream_find_raw(blorp_Stream* stream, blorp_Closure* pred, void** out) {
    if (!stream || !pred) return false;
    void* val;
    while (stream->pull(stream, &val)) {
        if ((long)blorp_call1(pred, val)) {
            *out = val;
            return true;
        }
        blorp_stream_release_pulled_if_owned(stream, val);
    }
    return false;
}

blorp_Option* blorp_stream_find(blorp_Stream* stream, blorp_Closure* pred) {
    void* val = NULL;
    if (!blorp_stream_find_raw(stream, pred, &val)) return blorp_option_none();
    if (stream->elem_is_rc && !stream->elem_is_owned && val) blorp_retain(val);
    blorp_Option* opt = blorp_option_some(val);
    if (stream->elem_is_rc) opt->release_mask = 1UL;
    return opt;
}

#define BLORP_DEFINE_STREAM_FIND_STACK_OPTION(PUBLIC_SUFFIX, STACK_SUFFIX, NAME, CTYPE, UNBOX) \
blorp_StackOption_##NAME blorp_stream_find_##PUBLIC_SUFFIX(blorp_Stream* stream, blorp_Closure* pred) { \
    void* value = NULL; \
    if (!blorp_stream_find_raw(stream, pred, &value)) return blorp_stack_option_##STACK_SUFFIX##_none(); \
    return blorp_stack_option_##STACK_SUFFIX##_some((CTYPE)UNBOX(value)); \
}

BLORP_DEFINE_STREAM_FIND_STACK_OPTION(int, int, Int, long, blorp_channel_unbox_long)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(int8, int8, Int8, int8_t, blorp_channel_unbox_int8)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(int16, int16, Int16, int16_t, blorp_channel_unbox_int16)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(int32, int32, Int32, int32_t, blorp_channel_unbox_int32)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(int64, int64, Int64, long, blorp_channel_unbox_long)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(uint8, uint8, UInt8, uint8_t, blorp_channel_unbox_uint8)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(uint16, uint16, UInt16, uint16_t, blorp_channel_unbox_uint16)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(uint32, uint32, UInt32, uint32_t, blorp_channel_unbox_uint32)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(uint64, uint64, UInt64, uint64_t, blorp_channel_unbox_uint64)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(float, float, Float, double, blorp_unbox_float)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(bool, bool, Bool, long, blorp_channel_unbox_bool)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(char, char, Char, int32_t, blorp_channel_unbox_int32)
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(f32, float32, Float32, float, blorp_unbox_float32)
#ifdef __FLT16_MAX__
BLORP_DEFINE_STREAM_FIND_STACK_OPTION(f16, float16, Float16, _Float16, blorp_unbox_float16)
#endif

#undef BLORP_DEFINE_STREAM_FIND_STACK_OPTION

void* blorp_stream_find_nullable(blorp_Stream* stream, blorp_Closure* pred) {
    void* val = NULL;
    if (!blorp_stream_find_raw(stream, pred, &val)) return NULL;
    if (stream->elem_is_rc && !stream->elem_is_owned && val) blorp_retain(val);
    return val;
}

// --- Terminal: any ---
bool blorp_stream_any(blorp_Stream* stream, blorp_Closure* pred) {
    if (!stream || !pred) return false;
    void* val;
    while (stream->pull(stream, &val)) {
        long keep = (long)blorp_call1(pred, val);
        blorp_stream_release_pulled_if_owned(stream, val);
        if (keep) return true;
    }
    return false;
}

// --- Terminal: all ---
bool blorp_stream_all(blorp_Stream* stream, blorp_Closure* pred) {
    if (!stream || !pred) return true;
    void* val;
    while (stream->pull(stream, &val)) {
        long keep = (long)blorp_call1(pred, val);
        blorp_stream_release_pulled_if_owned(stream, val);
        if (!keep) return false;
    }
    return true;
}

// --- from_lines ---
static bool stream_lines_pull(blorp_Stream* self, void** out) {
    StreamLinesState* st = (StreamLinesState*)self->state;
    if (!st->fp) return false;
    ssize_t len = getline(&st->buf, &st->buf_size, st->fp);
    if (len < 0) {
        fclose(st->fp);
        st->fp = NULL;
        return false;
    }
    // Strip trailing newline
    while (len > 0 && (st->buf[len-1] == '\n' || st->buf[len-1] == '\r')) len--;
    blorp_String* line = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    line->len = len;
    line->capacity = len;
    memcpy(line->data, st->buf, len);
    line->data[len] = '\0';
    *out = line;
    return true;
}
static void stream_lines_cleanup(blorp_Stream* self) {
    StreamLinesState* st = (StreamLinesState*)self->state;
    if (st->fp) fclose(st->fp);
    free(st->buf);
    free(st);
}
blorp_Stream* blorp_stream_from_lines(blorp_String* path) {
    if (!path) return blorp_stream_empty();
    char pathbuf[4096];
    long plen = path->len < 4095 ? path->len : 4095;
    memcpy(pathbuf, path->data, plen);
    pathbuf[plen] = '\0';
    FILE* fp = fopen(pathbuf, "r");
    if (!fp) return blorp_stream_empty();
    blorp_Stream* s = blorp_stream_new();
    s->elem_is_rc = true;  // Stream[String] — strings are RC
    StreamLinesState* st = malloc(sizeof(StreamLinesState));
    st->fp = fp;
    st->buf = NULL;
    st->buf_size = 0;
    s->state = st;
    s->pull = stream_lines_pull;
    s->state_cleanup = stream_lines_cleanup;
    return s;
}

// --- Raw pull for for-in codegen ---
bool blorp_stream_next_raw(blorp_Stream* stream, void** out) {
    if (!stream) return false;
    return stream->pull(stream, out);
}


// ============================================================================
// Closure Support
// ============================================================================

// Note: blorp_Closure is forward-declared in the Parallel Operations section above
// Note: blorp_closure_env_is_inline is also defined in runtime_decl.c for generated code

static inline int blorp_closure_env_is_inline(blorp_Closure* c) {
    return c->env == (void*)((char*)c + sizeof(blorp_Closure));
}

static void blorp_closure_destroy(void* obj) {
    blorp_Closure* c = (blorp_Closure*)obj;
    if (c->env && c->env_release_mask) {
        void** slots = (void**)c->env;
        for (long i = 0; i < c->env_count; i++) {
            if (((c->env_release_mask >> i) & 1UL) && slots[i]) {
                blorp_release(slots[i]);
            }
        }
    }
    if (c->env && !blorp_closure_env_is_inline(c)) free(c->env);
}

blorp_Closure* blorp_closure_new(void* func, void* env) {
    blorp_Closure* c = (blorp_Closure*)blorp_alloc(sizeof(blorp_Closure));
    BLORP_TAG(c, "Closure");
    c->func = func;
    c->env = env;
    c->env_count = 0;
    c->env_release_mask = 0;
    BLORP_SET_DESTRUCTOR(c, blorp_closure_destroy);
    return c;
}

blorp_Closure* blorp_closure_new_inline(void* func, int n) {
    blorp_Closure* c = (blorp_Closure*)blorp_alloc(sizeof(blorp_Closure) + n * sizeof(void*));
    BLORP_TAG(c, "Closure");
    c->func = func;
    c->env = (void*)((char*)c + sizeof(blorp_Closure));
    c->env_count = n;
    c->env_release_mask = 0;
    BLORP_SET_DESTRUCTOR(c, blorp_closure_destroy);
    return c;
}

// ============================================================================
// Fixed-Point Decimal Support
// ============================================================================

typedef struct {
    blorp_Object header;
    long value;      // Scaled integer value
    int scale;       // Decimal places (can be negative for large numbers)
    int precision;   // Total digits (default 18)
} blorp_Fixed;

// Power of 10 helper
long blorp_pow10(int n) {
    if (n < 0) return 1;  // For negative, we divide instead
    long result = 1;
    for (int i = 0; i < n && i < 18; i++) result *= 10;
    return result;
}

// Normalize precision to valid range (minimum 1, default 18)
static int blorp_normalize_precision(int p) {
    return p < 1 ? 18 : p;
}

// Create Fixed from double
blorp_Fixed* blorp_fixed_new(double value, int scale, int precision) {
    blorp_Fixed* f = (blorp_Fixed*)blorp_alloc(sizeof(blorp_Fixed));
    f->precision = blorp_normalize_precision(precision);
    f->scale = scale;
    if (scale >= 0) {
        f->value = (long)round(value * blorp_pow10(scale));
    } else {
        f->value = (long)round(value / blorp_pow10(-scale));
    }
    return f;
}

// Create Fixed from integer
blorp_Fixed* blorp_fixed_from_int(long value, int scale, int precision) {
    blorp_Fixed* f = (blorp_Fixed*)blorp_alloc(sizeof(blorp_Fixed));
    f->precision = blorp_normalize_precision(precision);
    f->scale = scale;
    if (scale >= 0) {
        __int128 wide = (__int128)value * (__int128)blorp_pow10(scale);
        f->value = (wide > LONG_MAX) ? LONG_MAX : (wide < LONG_MIN) ? LONG_MIN : (long)wide;
    } else {
        f->value = value / blorp_pow10(-scale);
    }
    return f;
}

// Create Fixed from raw value
blorp_Fixed* blorp_fixed_raw(long value, int scale, int precision) {
    blorp_Fixed* f = (blorp_Fixed*)blorp_alloc(sizeof(blorp_Fixed));
    f->value = value;
    f->scale = scale;
    f->precision = blorp_normalize_precision(precision);
    return f;
}

// Scale a Fixed value to a new scale
static long blorp_fixed_scale_to(blorp_Fixed* f, int target_scale) {
    int diff = target_scale - f->scale;
    if (diff > 0) {
        return f->value * blorp_pow10(diff);
    } else if (diff < 0) {
        long divisor = blorp_pow10(-diff);
        // Round to nearest
        return (f->value + divisor/2) / divisor;
    }
    return f->value;
}

// Addition (auto-normalize to max scale)
blorp_Fixed* blorp_fixed_add(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    int max_prec = a->precision > b->precision ? a->precision : b->precision;
    long va = blorp_fixed_scale_to(a, max_scale);
    long vb = blorp_fixed_scale_to(b, max_scale);
    return blorp_fixed_raw(va + vb, max_scale, max_prec);
}

// Subtraction
blorp_Fixed* blorp_fixed_sub(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    int max_prec = a->precision > b->precision ? a->precision : b->precision;
    long va = blorp_fixed_scale_to(a, max_scale);
    long vb = blorp_fixed_scale_to(b, max_scale);
    return blorp_fixed_raw(va - vb, max_scale, max_prec);
}

// Multiplication (scales add)
blorp_Fixed* blorp_fixed_mul(blorp_Fixed* a, blorp_Fixed* b) {
    int new_scale = a->scale + b->scale;
    int max_prec = a->precision > b->precision ? a->precision : b->precision;
    // Use __int128 to detect overflow
    __int128 wide = (__int128)a->value * (__int128)b->value;
    long result = (wide > LONG_MAX) ? LONG_MAX : (wide < LONG_MIN) ? LONG_MIN : (long)wide;
    return blorp_fixed_raw(result, new_scale, max_prec);
}

// Division (use extended precision, then round)
// Safe: returns zero Fixed on division by zero (consistent with Int/Float)
blorp_Fixed* blorp_fixed_div(blorp_Fixed* a, blorp_Fixed* b) {
    if (b->value == 0) {
        // Return zero with same scale/precision as dividend
        return blorp_fixed_raw(0, a->scale, a->precision);
    }
    // Use extra precision for division, then result has a.scale - b.scale + extra
    int extra_precision = 10;
    int result_scale = a->scale - b->scale + extra_precision;
    int max_prec = a->precision > b->precision ? a->precision : b->precision;
    // Use __int128 to detect overflow in scaling
    __int128 wide_a = (__int128)a->value * (__int128)blorp_pow10(extra_precision);
    long scaled_a = (wide_a > LONG_MAX) ? LONG_MAX : (wide_a < LONG_MIN) ? LONG_MIN : (long)wide_a;
    return blorp_fixed_raw(scaled_a / b->value, result_scale, max_prec);
}

// (blorp_fixed_neg removed — now IR intrinsic)

// Comparisons (auto-normalize for comparison)
bool blorp_fixed_eq(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    return blorp_fixed_scale_to(a, max_scale) == blorp_fixed_scale_to(b, max_scale);
}

bool blorp_fixed_lt(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    return blorp_fixed_scale_to(a, max_scale) < blorp_fixed_scale_to(b, max_scale);
}

bool blorp_fixed_le(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    return blorp_fixed_scale_to(a, max_scale) <= blorp_fixed_scale_to(b, max_scale);
}

bool blorp_fixed_gt(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    return blorp_fixed_scale_to(a, max_scale) > blorp_fixed_scale_to(b, max_scale);
}

bool blorp_fixed_ge(blorp_Fixed* a, blorp_Fixed* b) {
    int max_scale = a->scale > b->scale ? a->scale : b->scale;
    return blorp_fixed_scale_to(a, max_scale) >= blorp_fixed_scale_to(b, max_scale);
}

// (blorp_fixed_round_to removed — now IR intrinsic)

// Convert to string
blorp_String* blorp_fixed_to_string(blorp_Fixed* f) {
    char buf[64];
    int len;
    if (f->scale >= 0) {
        long divisor = blorp_pow10(f->scale);
        long integer_part = f->value / divisor;
        long frac_part = f->value % divisor;
        if (frac_part < 0) frac_part = -frac_part;
        if (f->scale == 0) {
            len = snprintf(buf, sizeof(buf), "%ld", integer_part);
        } else {
            len = snprintf(buf, sizeof(buf), "%ld.%0*ld", integer_part, f->scale, frac_part);
        }
    } else {
        // Negative scale - multiply by power of 10
        len = snprintf(buf, sizeof(buf), "%ld", f->value * blorp_pow10(-f->scale));
    }
    blorp_String* str = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    str->len = len;
    str->capacity = len;
    memcpy(str->data, buf, len);
    str->data[len] = '\0';
    return str;
}

// (blorp_fixed_to_int, get_scale, get_precision removed — now IR intrinsics)

// Convert to float
double blorp_fixed_to_float(blorp_Fixed* f) {
    if (f->scale >= 0) {
        return (double)f->value / blorp_pow10(f->scale);
    } else {
        return (double)f->value * blorp_pow10(-f->scale);
    }
}

// ============================================================================
// String Utility Functions
// ============================================================================

blorp_String* blorp_substring(const blorp_String* s, long start, long len) {
    if (!s || start < 0 || start >= s->len) {
        return __blorp_empty_str;
    }
    if (len < 0 || start + len > s->len) {
        len = s->len - start;
    }
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    memcpy(result->data, s->data + start, len);
    result->data[len] = '\0';
    return result;
}

// (removed blorp_starts_with — now IR intrinsic)
// (removed blorp_ends_with — now IR intrinsic)
// (removed blorp_contains [string version] — now IR intrinsic)
// (removed blorp_index_of [string version] — now IR intrinsic)
// (removed blorp_split — now std source)
// (removed blorp_join — now std source)

// (removed blorp_trim — now IR intrinsic)
// (removed blorp_replace — now std source)

// (removed blorp_capitalize — now IR intrinsic)
// (removed blorp_equal_ignore_case — now std source)
// (removed blorp_title_case — now IR intrinsic)
// (removed blorp_string_repeat — now IR intrinsic)

// ============================================================================
// URL Encoding/Decoding (RFC 3986)
// ============================================================================

// url_encode: percent-encode non-unreserved characters
blorp_String* blorp_url_encode(const blorp_String* s) {
    if (!s || s->len == 0) return __blorp_empty_str;
    // Worst case: every byte becomes %XX (3x expansion)
    size_t max_len = blorp_checked_mul(s->len, 3);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + max_len + 1);
    long j = 0;
    for (long i = 0; i < s->len; i++) {
        unsigned char c = (unsigned char)s->data[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            result->data[j++] = c;
        } else {
            result->data[j++] = '%';
            result->data[j++] = "0123456789ABCDEF"[c >> 4];
            result->data[j++] = "0123456789ABCDEF"[c & 0x0F];
        }
    }
    result->data[j] = '\0';
    result->len = j;
    result->capacity = j;
    return result;
}

// url_decode: decode percent-encoded sequences and + as space
blorp_String* blorp_url_decode(const blorp_String* s) {
    if (!s || s->len == 0) return __blorp_empty_str;
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + s->len + 1);
    long j = 0;
    for (long i = 0; i < s->len; i++) {
        if (s->data[i] == '%' && i + 2 < s->len) {
            unsigned char hi = s->data[i+1];
            unsigned char lo = s->data[i+2];
            int h = (hi >= '0' && hi <= '9') ? hi - '0' :
                    (hi >= 'A' && hi <= 'F') ? hi - 'A' + 10 :
                    (hi >= 'a' && hi <= 'f') ? hi - 'a' + 10 : -1;
            int l = (lo >= '0' && lo <= '9') ? lo - '0' :
                    (lo >= 'A' && lo <= 'F') ? lo - 'A' + 10 :
                    (lo >= 'a' && lo <= 'f') ? lo - 'a' + 10 : -1;
            if (h >= 0 && l >= 0) {
                result->data[j++] = (char)(h * 16 + l);
                i += 2;
            } else {
                result->data[j++] = s->data[i];
            }
        } else if (s->data[i] == '+') {
            result->data[j++] = ' ';
        } else {
            result->data[j++] = s->data[i];
        }
    }
    result->data[j] = '\0';
    result->len = j;
    result->capacity = j;
    return result;
}

// ============================================================================
// HTML Escaping
// ============================================================================

// html_escape: escape <, >, &, ", ' for safe HTML embedding
blorp_String* blorp_html_escape(const blorp_String* s) {
    if (!s || s->len == 0) return __blorp_empty_str;
    // Worst case: every char is & -> &amp; (5x)
    size_t max_len = blorp_checked_mul(s->len, 6);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + max_len + 1);
    long j = 0;
    for (long i = 0; i < s->len; i++) {
        switch (s->data[i]) {
            case '&':
                memcpy(result->data + j, "&amp;", 5); j += 5; break;
            case '<':
                memcpy(result->data + j, "&lt;", 4); j += 4; break;
            case '>':
                memcpy(result->data + j, "&gt;", 4); j += 4; break;
            case '"':
                memcpy(result->data + j, "&quot;", 6); j += 6; break;
            case '\'':
                memcpy(result->data + j, "&#39;", 5); j += 5; break;
            default:
                result->data[j++] = s->data[i]; break;
        }
    }
    result->data[j] = '\0';
    result->len = j;
    result->capacity = j;
    return result;
}

// ============================================================================
// Additional String Operations
// ============================================================================

// (removed blorp_drop_left — now IR intrinsic)
// (removed blorp_take_left — now IR intrinsic)
// (removed blorp_trim_left — now IR intrinsic)
// (removed blorp_trim_right — now IR intrinsic)
// (removed blorp_string_count — now IR intrinsic)
// (removed blorp_lines — now std source)

// (removed blorp_string_reverse — now IR intrinsic)
// (removed blorp_pad_left — now IR intrinsic)
// (removed blorp_pad_right — now IR intrinsic)
// (removed blorp_words — now std source)

// codepoint_length: count UTF-8 codepoints (not bytes)
long blorp_codepoint_length(const blorp_String* s) {
    if (!s || s->len == 0) return 0;
    long count = 0;
    for (long i = 0; i < s->len; ) {
        unsigned char c = (unsigned char)s->data[i];
        if (c < 0x80) i += 1;
        else if ((c & 0xE0) == 0xC0) i += 2;
        else if ((c & 0xF0) == 0xE0) i += 3;
        else if ((c & 0xF8) == 0xF0) i += 4;
        else i += 1;  // invalid byte, skip
        count++;
    }
    return count;
}

// Decode a single UTF-8 codepoint starting at *pos, advance *pos past it.
static inline int32_t blorp_string_next_codepoint(const blorp_String* s, long* pos) {
    unsigned char c = (unsigned char)s->data[*pos];
    int32_t cp;
    if (c < 0x80) { cp = c; *pos += 1; }
    else if ((c & 0xE0) == 0xC0 && *pos + 1 < s->len) {
        cp = ((c & 0x1F) << 6) | (s->data[*pos+1] & 0x3F); *pos += 2;
    } else if ((c & 0xF0) == 0xE0 && *pos + 2 < s->len) {
        cp = ((c & 0x0F) << 12) | ((s->data[*pos+1] & 0x3F) << 6) | (s->data[*pos+2] & 0x3F); *pos += 3;
    } else if ((c & 0xF8) == 0xF0 && *pos + 3 < s->len) {
        cp = ((c & 0x07) << 18) | ((s->data[*pos+1] & 0x3F) << 12) | ((s->data[*pos+2] & 0x3F) << 6) | (s->data[*pos+3] & 0x3F); *pos += 4;
    } else { cp = c; *pos += 1; }
    return cp;
}

// codepoints: decode UTF-8 string into list of codepoints as Int
blorp_List* blorp_string_codepoints(const blorp_String* s) {
    blorp_List* result = blorp_list_new_inline(s ? s->len : 0, 8);
    if (!s || s->len == 0) return result;
    for (long i = 0; i < s->len; ) {
        int32_t cp = blorp_string_next_codepoint(s, &i);
        result = blorp_list_append(result, (void*)(long)cp);
    }
    return result;
}

// codepoint_reverse: reverse a UTF-8 string by codepoints (not bytes)
blorp_String* blorp_codepoint_reverse(const blorp_String* s) {
    if (!s || s->len == 0) return blorp_string_literal("");
    // Collect byte ranges for each codepoint
    long* starts = (long*)blorp_malloc_checked(sizeof(long) * s->len);
    long* lens = (long*)blorp_malloc_checked(sizeof(long) * s->len);
    long n = 0;
    for (long i = 0; i < s->len; ) {
        unsigned char c = (unsigned char)s->data[i];
        long cp_len;
        if (c < 0x80) cp_len = 1;
        else if ((c & 0xE0) == 0xC0) cp_len = 2;
        else if ((c & 0xF0) == 0xE0) cp_len = 3;
        else if ((c & 0xF8) == 0xF0) cp_len = 4;
        else cp_len = 1;
        if (i + cp_len > s->len) cp_len = 1;
        starts[n] = i;
        lens[n] = cp_len;
        n++;
        i += cp_len;
    }
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + s->len + 1);
    result->len = s->len;
    result->capacity = s->len;
    long pos = 0;
    for (long i = n - 1; i >= 0; i--) {
        memcpy(result->data + pos, s->data + starts[i], lens[i]);
        pos += lens[i];
    }
    result->data[s->len] = '\0';
    free(starts);
    free(lens);
    return result;
}

// (removed blorp_split_n — now std source)
// (removed blorp_replace_first — now std source)

// (removed blorp_last_index_of — now IR intrinsic)
// (removed blorp_trim_chars — now IR intrinsic)
// (removed blorp_take_right — now IR intrinsic)
// (removed blorp_drop_right — now IR intrinsic)
// (removed blorp_center — now IR intrinsic)

// ============================================================================
// String Analysis Builtins
// ============================================================================

// chars(s) -> List[Char] — O(n), single list allocation, no Option overhead
blorp_List* blorp_string_chars(const blorp_String* s) {
    if (!s || s->len == 0) return blorp_list_new_inline(0, 4);
    blorp_List* result = blorp_list_new_inline(s->len, 4);
    for (long i = 0; i < s->len; i++) {
        result = blorp_list_append(result, (void*)(long)(int32_t)(unsigned char)s->data[i]);
    }
    return result;
}

// (removed blorp_string_is_numeric — now IR intrinsic)
// (removed blorp_string_is_ascii — now IR intrinsic)
// (removed blorp_string_is_blank — now IR intrinsic)
// (removed blorp_string_is_lower — now IR intrinsic)
// (removed blorp_string_is_upper — now IR intrinsic)
// (removed blorp_string_hamming — now IR intrinsic)
// (removed blorp_string_common_prefix — now IR intrinsic)

// levenshtein(a, b) -> Int — edit distance, O(n*m) time, O(min(n,m)) space
long blorp_string_levenshtein(const blorp_String* a, const blorp_String* b) {
    if (!a || a->len == 0) return b ? b->len : 0;
    if (!b || b->len == 0) return a->len;
    // Use shorter string as columns to minimize memory
    const blorp_String* row_s = a->len <= b->len ? a : b;
    const blorp_String* col_s = a->len <= b->len ? b : a;
    long cols = row_s->len;
    long rows = col_s->len;
    long* prev = malloc((cols + 1) * sizeof(long));
    long* curr = malloc((cols + 1) * sizeof(long));
    if (!prev || !curr) { free(prev); free(curr); return rows; }
    for (long j = 0; j <= cols; j++) prev[j] = j;
    for (long i = 1; i <= rows; i++) {
        curr[0] = i;
        for (long j = 1; j <= cols; j++) {
            long cost = (col_s->data[i-1] == row_s->data[j-1]) ? 0 : 1;
            long del = prev[j] + 1;
            long ins = curr[j-1] + 1;
            long sub = prev[j-1] + cost;
            long mn = del < ins ? del : ins;
            curr[j] = mn < sub ? mn : sub;
        }
        long* tmp = prev; prev = curr; curr = tmp;
    }
    long result = prev[cols];
    free(prev); free(curr);
    return result;
}

// longest_common_substring(a, b) -> String — O(n*m) DP
blorp_String* blorp_string_lcs(const blorp_String* a, const blorp_String* b) {
    if (!a || !b || a->len == 0 || b->len == 0)
        return blorp_string_create("");
    long m = a->len, n = b->len;
    long best_len = 0, best_end = 0;
    long* dp = calloc(n + 1, sizeof(long));
    if (!dp) return blorp_string_create("");
    for (long i = 1; i <= m; i++) {
        for (long j = n; j >= 1; j--) {
            if (a->data[i-1] == b->data[j-1]) {
                dp[j] = dp[j-1] + 1;
                if (dp[j] > best_len) {
                    best_len = dp[j];
                    best_end = i;
                }
            } else {
                dp[j] = 0;
            }
        }
    }
    free(dp);
    if (best_len == 0) return blorp_string_create("");
    return blorp_substring(a, best_end - best_len, best_len);
}

#include <regex.h>

// Thread-local LRU cache for compiled regex patterns
#define BLORP_REGEX_CACHE_SIZE 32

typedef struct {
    char* pattern;
    regex_t compiled;
    int valid;
} blorp_regex_entry;

static _Thread_local blorp_regex_entry blorp_regex_cache[BLORP_REGEX_CACHE_SIZE];
static _Thread_local int blorp_regex_cache_next = 0;

// Compile a regex pattern, returning cached version if available
// Returns 0 on success, non-zero on error (fills errbuf)
static int blorp_regex_compile(const char* pattern, regex_t** out, char* errbuf, size_t errbuf_size) {
    // Search cache
    for (int i = 0; i < BLORP_REGEX_CACHE_SIZE; i++) {
        if (blorp_regex_cache[i].valid && strcmp(blorp_regex_cache[i].pattern, pattern) == 0) {
            *out = &blorp_regex_cache[i].compiled;
            return 0;
        }
    }
    // Evict oldest entry
    int slot = blorp_regex_cache_next;
    blorp_regex_cache_next = (blorp_regex_cache_next + 1) % BLORP_REGEX_CACHE_SIZE;
    if (blorp_regex_cache[slot].valid) {
        regfree(&blorp_regex_cache[slot].compiled);
        free(blorp_regex_cache[slot].pattern);
    }
    int err = regcomp(&blorp_regex_cache[slot].compiled, pattern, REG_EXTENDED);
    if (err != 0) {
        regerror(err, &blorp_regex_cache[slot].compiled, errbuf, errbuf_size);
        blorp_regex_cache[slot].valid = 0;
        blorp_regex_cache[slot].pattern = NULL;
        return err;
    }
    blorp_regex_cache[slot].pattern = strdup(pattern);
    blorp_regex_cache[slot].valid = 1;
    *out = &blorp_regex_cache[slot].compiled;
    return 0;
}

// test(pattern, text) -> Result[Bool, String]
blorp_Result* blorp_regex_test(const blorp_String* pattern, const blorp_String* text) {
    if (!pattern || !text) return blorp_result_ok((void*)0);

    char errbuf[256];
    regex_t* compiled;
    int err = blorp_regex_compile(pattern->data, &compiled, errbuf, sizeof(errbuf));
    if (err != 0) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }

    int match = regexec(compiled, text->data, 0, NULL, 0);
    return blorp_result_ok((void*)(long)(match == 0));
}

// find(pattern, text) -> Result[Option[List[String]], String]
blorp_Result* blorp_regex_find(const blorp_String* pattern, const blorp_String* text) {
    if (!pattern || !text) {
        return blorp_result_ok(NULL);
    }

    char errbuf[256];
    regex_t* compiled;
    int err = blorp_regex_compile(pattern->data, &compiled, errbuf, sizeof(errbuf));
    if (err != 0) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }

    regmatch_t matches[33]; // 32 groups + full match
    int result = regexec(compiled, text->data, 33, matches, 0);
    if (result != 0) {
        return blorp_result_ok(NULL);
    }

    // Build list of captures (index 0 = full match, 1+ = groups)
    blorp_List* captures = blorp_list_new(8);
    for (int i = 0; i < 33 && matches[i].rm_so != -1; i++) {
        long start = matches[i].rm_so;
        long end = matches[i].rm_eo;
        long len = end - start;
        blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
        s->len = len;
        s->capacity = len;
        memcpy(s->data, text->data + start, len);
        s->data[len] = '\0';
        captures = blorp_list_append(captures, (void*)s);
    }
    blorp_list_init_elem_release(captures, blorp_elem_release_fn);
    blorp_Result* res = blorp_result_ok((void*)captures);
    res->release_mask = 1UL;
    return res;
}

// replace_all(pattern, replacement, text) -> Result[String, String]
blorp_Result* blorp_regex_replace_all(const blorp_String* pattern, const blorp_String* replacement, const blorp_String* text) {
    if (!pattern || !replacement || !text) {
        blorp_Result* res = blorp_result_ok((void*)__blorp_empty_str);
        res->release_mask = 1UL;
        return res;
    }

    char errbuf[256];
    regex_t* compiled;
    int err = blorp_regex_compile(pattern->data, &compiled, errbuf, sizeof(errbuf));
    if (err != 0) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }

    // Build result string by iterating through matches
    long rep_len = replacement->len;
    long txt_len = text->len;
    const char* ctxt = text->data;
    const char* crep = replacement->data;
    // Estimate capacity
    long cap = txt_len * 2 + 64;
    char* buf = (char*)blorp_malloc_checked(cap);
    long buf_len = 0;
    long offset = 0;

    regmatch_t match;
    while (offset <= txt_len && regexec(compiled, ctxt + offset, 1, &match, offset > 0 ? REG_NOTBOL : 0) == 0) {
        long start = match.rm_so;
        long end = match.rm_eo;

        // Copy text before match
        if (buf_len + start + rep_len + 1 > cap) {
            cap = (buf_len + start + rep_len + 1) * 2;
            char* new_buf = (char*)realloc(buf, cap);
            if (!new_buf) { free(buf); fprintf(stderr, "blorp: out of memory (realloc %ld bytes)\\n", cap); exit(1); }
            buf = new_buf;
        }
        memcpy(buf + buf_len, ctxt + offset, start);
        buf_len += start;

        // Copy replacement
        memcpy(buf + buf_len, crep, rep_len);
        buf_len += rep_len;

        offset += end;
        if (end == start) offset++; // Avoid infinite loop on zero-width match
    }

    // Copy remaining text
    long remaining = txt_len - offset;
    if (remaining > 0) {
        if (buf_len + remaining + 1 > cap) {
            cap = buf_len + remaining + 1;
            char* new_buf = (char*)realloc(buf, cap);
            if (!new_buf) { free(buf); fprintf(stderr, "blorp: out of memory (realloc %ld bytes)\\n", cap); exit(1); }
            buf = new_buf;
        }
        memcpy(buf + buf_len, ctxt + offset, remaining);
        buf_len += remaining;
    }

    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + buf_len + 1);
    result->len = buf_len;
    result->capacity = buf_len;
    memcpy(result->data, buf, buf_len);
    result->data[buf_len] = '\0';

    free(buf);
    blorp_Result* res = blorp_result_ok((void*)result);
    res->release_mask = 1UL;
    return res;
}

// find_all(pattern, text) -> Result[List[String], String]
blorp_Result* blorp_regex_find_all(const blorp_String* pattern, const blorp_String* text) {
    if (!pattern || !text) {
        blorp_Result* res = blorp_result_ok((void*)blorp_list_new(0));
        res->release_mask = 1UL;
        return res;
    }

    char errbuf[256];
    regex_t* compiled;
    int err = blorp_regex_compile(pattern->data, &compiled, errbuf, sizeof(errbuf));
    if (err != 0) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }

    blorp_List* results = blorp_list_new(8);
    long offset = 0;
    long txt_len = text->len;
    const char* ctxt = text->data;
    regmatch_t match;

    while (offset <= txt_len && regexec(compiled, ctxt + offset, 1, &match, offset > 0 ? REG_NOTBOL : 0) == 0) {
        long start = match.rm_so;
        long end = match.rm_eo;
        long len = end - start;

        blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
        s->len = len;
        s->capacity = len;
        memcpy(s->data, ctxt + offset + start, len);
        s->data[len] = '\0';
        results = blorp_list_append(results, (void*)s);

        offset += end;
        if (end == start) offset++; // Avoid infinite loop on zero-width match
    }

    // Set elem_release AFTER all appends to avoid double-retain.
    // blorp_list_init_elem_release sets the release fn without retaining
    // existing elements (they were inserted at refcount 1, which is correct).
    blorp_list_init_elem_release(results, blorp_elem_release_fn);
    blorp_Result* res = blorp_result_ok((void*)results);
    res->release_mask = 1UL;
    return res;
}

// ============================================================================
// StringSlice Operations (zero-copy string views)
// ============================================================================

typedef struct {
    blorp_Object header;
    blorp_String* source;  // Reference to source string (retained)
    long start;
    long len;
} blorp_StringSlice;

static void blorp_slice_destructor(void* obj) {
    blorp_StringSlice* slice = (blorp_StringSlice*)obj;
    if (slice->source) blorp_release(slice->source);
}

// Allocate a slice with given source, start, len (retains source, sets destructor)
blorp_StringSlice* blorp_slice_alloc(blorp_String* source, long start, long len) {
    blorp_StringSlice* slice = (blorp_StringSlice*)blorp_alloc(sizeof(blorp_StringSlice));
    BLORP_SET_DESTRUCTOR(slice, blorp_slice_destructor);
    slice->source = (blorp_String*)blorp_retain(source);
    slice->start = start;
    slice->len = len;
    return slice;
}

// (slice_from_string, slice_length, slice_char_at, slice_get_opt,
//  slice_to_string, slice_substring, slice_starts_with — now IR intrinsics)

// ============================================================================
// File I/O Functions
// ============================================================================

blorp_Result* blorp_read_file(const blorp_String* path) {
    if (!path) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("read_file: null path"));
        res->release_mask = 1UL;
        return res;
    }

    // Null-terminate the path for fopen
    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "rb");
    if (!f) {
        const char* err = strerror(errno);
        // Build error message: "path: error"
        long elen = strlen(err);
        blorp_String* msg = (blorp_String*)blorp_alloc(sizeof(blorp_String) + path->len + 2 + elen + 1);
        memcpy(msg->data, cpath, path->len);
        msg->data[path->len] = ':';
        msg->data[path->len + 1] = ' ';
        memcpy(msg->data + path->len + 2, err, elen);
        msg->len = path->len + 2 + elen;
        msg->capacity = msg->len;
        msg->data[msg->len] = '\0';
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)msg);
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    if (len < 0) {
        fclose(f);
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("read_file: non-seekable file"));
        res->release_mask = 1UL;
        return res;
    }
    fseek(f, 0, SEEK_SET);

    blorp_String* content = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    content->len = len;
    content->capacity = len;
    if (len > 0) {
        fread(content->data, 1, len, f);
    }
    content->data[len] = '\0';
    fclose(f);

    blorp_Result* res = blorp_result_ok((void*)content);
    res->release_mask = 1UL;
    return res;
}

blorp_Result* blorp_write_file(const blorp_String* path, const blorp_String* content) {
    if (!path) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("write_file: null path"));
        res->release_mask = 1UL;
        return res;
    }

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "wb");
    if (!f) {
        const char* err = strerror(errno);
        long elen = strlen(err);
        blorp_String* msg = (blorp_String*)blorp_alloc(sizeof(blorp_String) + path->len + 2 + elen + 1);
        memcpy(msg->data, cpath, path->len);
        msg->data[path->len] = ':';
        msg->data[path->len + 1] = ' ';
        memcpy(msg->data + path->len + 2, err, elen);
        msg->len = path->len + 2 + elen;
        msg->capacity = msg->len;
        msg->data[msg->len] = '\0';
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)msg);
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    if (content && content->len > 0) {
        fwrite(content->data, 1, content->len, f);
    }
    fclose(f);

    blorp_Result* res = blorp_result_ok(NULL);
    return res;
}

blorp_Result* blorp_read_bytes(const blorp_String* path) {
    if (!path) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("read_bytes: null path"));
        res->release_mask = 1UL;
        return res;
    }

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "rb");
    if (!f) {
        const char* err = strerror(errno);
        long elen = strlen(err);
        blorp_String* msg = (blorp_String*)blorp_alloc(sizeof(blorp_String) + path->len + 2 + elen + 1);
        memcpy(msg->data, cpath, path->len);
        msg->data[path->len] = ':';
        msg->data[path->len + 1] = ' ';
        memcpy(msg->data + path->len + 2, err, elen);
        msg->len = path->len + 2 + elen;
        msg->capacity = msg->len;
        msg->data[msg->len] = '\0';
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)msg);
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    if (len < 0) {
        fclose(f);
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("read_bytes: non-seekable file"));
        res->release_mask = 1UL;
        return res;
    }
    fseek(f, 0, SEEK_SET);

    blorp_Bytes* bcontents = (blorp_Bytes*)blorp_alloc(sizeof(blorp_Bytes) + len);
    bcontents->len = len;
    bcontents->capacity = len;
    if (len > 0) {
        fread(bcontents->data, 1, len, f);
    }
    fclose(f);

    blorp_Result* res = blorp_result_ok((void*)bcontents);
    res->release_mask = 1UL;
    return res;
}

blorp_Result* blorp_write_bytes(const blorp_String* path, const blorp_Bytes* content) {
    if (!path) {
        blorp_Result* res = blorp_result_err((void*)blorp_string_create("write_bytes: null path"));
        res->release_mask = 1UL;
        return res;
    }

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "wb");
    if (!f) {
        const char* err = strerror(errno);
        long elen = strlen(err);
        blorp_String* msg = (blorp_String*)blorp_alloc(sizeof(blorp_String) + path->len + 2 + elen + 1);
        memcpy(msg->data, cpath, path->len);
        msg->data[path->len] = ':';
        msg->data[path->len + 1] = ' ';
        memcpy(msg->data + path->len + 2, err, elen);
        msg->len = path->len + 2 + elen;
        msg->capacity = msg->len;
        msg->data[msg->len] = '\0';
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)msg);
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    if (content && content->len > 0) {
        fwrite(content->data, 1, content->len, f);
    }
    fclose(f);

    blorp_Result* res = blorp_result_ok(NULL);
    return res;
}

blorp_List* blorp_read_all_lines(const blorp_String* path) {
    blorp_List* result = blorp_list_new(16);
    if (!path) return result;

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "rb");
    free(cpath);

    if (!f) return result;

    char* line = NULL;
    size_t cap = 0;
    ssize_t len;
    while ((len = getline(&line, &cap, f)) != -1) {
        // Strip trailing \n, \r\n, or \r
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) {
            len--;
        }
        blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
        s->len = len;
        s->capacity = len;
        if (len > 0) memcpy(s->data, line, len);
        s->data[len] = '\0';
        result = blorp_list_append(result, (void*)s);
    }
    free(line);
    fclose(f);
    blorp_list_init_elem_release(result, blorp_elem_release_fn);
    return result;
}

// (removed blorp_write_lines — now IR intrinsic)

bool blorp_append_file(const blorp_String* path, const blorp_String* content) {
    if (!path) return false;

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "ab");
    free(cpath);

    if (!f) return false;

    if (content && content->len > 0) {
        fwrite(content->data, 1, content->len, f);
    }
    fclose(f);
    return true;
}

blorp_Result* blorp_for_each_line(const blorp_String* path, blorp_Closure* callback) {
    if (!path) return blorp_result_err((void*)blorp_string_literal("File not found: (null)"));

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "rb");
    if (!f) {
        char errbuf[512];
        snprintf(errbuf, sizeof(errbuf), "File not found: %s", cpath);
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    char* line = NULL;
    size_t cap = 0;
    ssize_t len;
    long line_num = 1;
    while ((len = getline(&line, &cap, f)) != -1) {
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) {
            len--;
        }
        blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
        s->len = len;
        s->capacity = len;
        if (len > 0) memcpy(s->data, line, len);
        s->data[len] = '\0';
        blorp_call2(callback, (void*)(long)line_num, (void*)s);
        blorp_release(s);
        line_num++;
    }
    free(line);
    fclose(f);
    return blorp_result_ok(NULL);
}

blorp_Result* blorp_for_each_chunk(const blorp_String* path, long chunk_size, blorp_Closure* callback) {
    if (!path) return blorp_result_err((void*)blorp_string_literal("File not found: (null)"));
    if (chunk_size <= 0) chunk_size = 4096;

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "rb");
    if (!f) {
        char errbuf[512];
        snprintf(errbuf, sizeof(errbuf), "File not found: %s", cpath);
        free(cpath);
        blorp_Result* res = blorp_result_err((void*)blorp_string_from_buf(errbuf, strlen(errbuf)));
        res->release_mask = 1UL;
        return res;
    }
    free(cpath);

    char* buf = (char*)blorp_malloc_checked(chunk_size);
    size_t nread;
    while ((nread = fread(buf, 1, (size_t)chunk_size, f)) > 0) {
        blorp_String* s = (blorp_String*)blorp_alloc(sizeof(blorp_String) + nread + 1);
        s->len = (long)nread;
        s->capacity = (long)nread;
        memcpy(s->data, buf, nread);
        s->data[nread] = '\0';
        blorp_call1(callback, (void*)s);
        blorp_release(s);
    }
    free(buf);
    fclose(f);
    return blorp_result_ok(NULL);
}

bool blorp_file_exists(const blorp_String* path) {
    if (!path) return false;

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    FILE* f = fopen(cpath, "r");
    free(cpath);

    if (f) {
        fclose(f);
        return true;
    }
    return false;
}

// ============================================================================
// System Functions
// ============================================================================

#include <dirent.h>
#include <sys/stat.h>

bool blorp_is_directory(const blorp_String* path) {
    if (!path) return false;

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    struct stat st;
    int result = stat(cpath, &st);
    free(cpath);

    return result == 0 && S_ISDIR(st.st_mode);
}

blorp_List* blorp_list_dir(const blorp_String* path) {
    blorp_List* result = blorp_list_new(16);
    if (!path) {
        blorp_list_init_elem_release(result, blorp_elem_release_fn);
        return result;
    }

    char* cpath = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(cpath, path->data, path->len);
    cpath[path->len] = '\0';

    DIR* dir = opendir(cpath);
    free(cpath);

    if (!dir) {
        blorp_list_init_elem_release(result, blorp_elem_release_fn);
        return result;
    }

    struct dirent* entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        result = blorp_list_append(result, (void*)blorp_string_from_buf(entry->d_name, strlen(entry->d_name)));
    }
    closedir(dir);
    blorp_list_init_elem_release(result, blorp_elem_release_fn);
    return result;
}

long blorp_exec(const blorp_String* command) {
    if (!command) return -1;

    char* cmd = (char*)blorp_malloc_checked(command->len + 1);
    memcpy(cmd, command->data, command->len);
    cmd[command->len] = '\0';

    int result = system(cmd);
    free(cmd);
    return result;
}

// ============================================================================
// Environment Variables
// ============================================================================

static blorp_String* blorp_getenv_result(const blorp_String* name) {
    if (!name) return NULL;

    // Null-terminate the name for getenv
    char* cname = (char*)blorp_malloc_checked(name->len + 1);
    memcpy(cname, name->data, name->len);
    cname[name->len] = '\0';

    char* value = getenv(cname);
    free(cname);

    if (!value) return NULL;

    // Create String from C string
    size_t len = strlen(value);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    memcpy(result->data, value, len);
    result->data[len] = '\0';
    return result;
}

blorp_String* blorp_getenv_nullable(const blorp_String* name) {
    return blorp_getenv_result(name);
}

blorp_String* blorp_getenv(const blorp_String* name) {
    return blorp_getenv_result(name);
}

bool blorp_setenv(const blorp_String* name, const blorp_String* value) {
    if (!name || !value) return false;

    // Null-terminate both strings
    char* cname = (char*)blorp_malloc_checked(name->len + 1);
    memcpy(cname, name->data, name->len);
    cname[name->len] = '\0';

    char* cvalue = (char*)blorp_malloc_checked(value->len + 1);
    memcpy(cvalue, value->data, value->len);
    cvalue[value->len] = '\0';

    int result = setenv(cname, cvalue, 1);  // 1 = overwrite existing

    free(cname);
    free(cvalue);

    return result == 0;
}

// ============================================================================
// Memory Stats (wired into blorp_alloc/blorp_release above)
// ============================================================================

blorp_MemStats* blorp_get_mem_stats(void) {
    __blorp_stats_enabled = true;  // Enable tracking when stats are requested
    blorp_MemStats* stats = (blorp_MemStats*)blorp_alloc_untracked(sizeof(blorp_MemStats));
    // MemStats is an observation object, not part of the measured program heap.
    stats->total_allocations = atomic_load(&global_mem_stats.total_allocations);
    stats->total_releases = atomic_load(&global_mem_stats.total_releases);
    stats->current_objects = atomic_load(&global_mem_stats.current_objects);
    stats->bytes_allocated = atomic_load(&global_mem_stats.bytes_allocated);
    return stats;
}

void blorp_reset_mem_stats(void) {
    __blorp_stats_enabled = true;  // Enable tracking when stats are reset
    atomic_fetch_add(&global_mem_stats.epoch, 1);
    atomic_store(&global_mem_stats.total_allocations, 0);
    atomic_store(&global_mem_stats.total_releases, 0);
    atomic_store(&global_mem_stats.current_objects, 0);
    atomic_store(&global_mem_stats.bytes_allocated, 0);
}

blorp_SchedulerStats* blorp_get_scheduler_stats(void) {
    atomic_store_explicit(
        &__blorp_scheduler_stats_enabled, 1, memory_order_relaxed);
    blorp_SchedulerStats* stats =
        (blorp_SchedulerStats*)blorp_alloc_untracked(
            sizeof(blorp_SchedulerStats));
    stats->tasks_spawned =
        atomic_load_explicit(&global_scheduler_stats.tasks_spawned,
            memory_order_relaxed);
    stats->fibers_created =
        atomic_load_explicit(&global_scheduler_stats.fibers_created,
            memory_order_relaxed);
    stats->fibers_reused =
        atomic_load_explicit(&global_scheduler_stats.fibers_reused,
            memory_order_relaxed);
    stats->fibers_completed =
        atomic_load_explicit(&global_scheduler_stats.fibers_completed,
            memory_order_relaxed);
    stats->fiber_resumes =
        atomic_load_explicit(&global_scheduler_stats.fiber_resumes,
            memory_order_relaxed);
    stats->fiber_parks =
        atomic_load_explicit(&global_scheduler_stats.fiber_parks,
            memory_order_relaxed);
    stats->fiber_schedule_transitions =
        atomic_load_explicit(
            &global_scheduler_stats.fiber_schedule_transitions,
            memory_order_relaxed);
    stats->runnable_enqueues =
        atomic_load_explicit(&global_scheduler_stats.runnable_enqueues,
            memory_order_relaxed);
    stats->run_queue_pops =
        atomic_load_explicit(&global_scheduler_stats.run_queue_pops,
            memory_order_relaxed);
    stats->timer_inserts =
        atomic_load_explicit(&global_scheduler_stats.timer_inserts,
            memory_order_relaxed);
    stats->timer_expirations =
        atomic_load_explicit(&global_scheduler_stats.timer_expirations,
            memory_order_relaxed);
    stats->reactor_control_wakes =
        atomic_load_explicit(&global_scheduler_stats.reactor_control_wakes,
            memory_order_relaxed);
    stats->reactor_poll_wakes =
        atomic_load_explicit(&global_scheduler_stats.reactor_poll_wakes,
            memory_order_relaxed);
    stats->reactor_ready_events =
        atomic_load_explicit(&global_scheduler_stats.reactor_ready_events,
            memory_order_relaxed);
    stats->reactor_waiter_wakes =
        atomic_load_explicit(&global_scheduler_stats.reactor_waiter_wakes,
            memory_order_relaxed);
    stats->stack_allocations =
        atomic_load_explicit(&global_scheduler_stats.stack_allocations,
            memory_order_relaxed);
    stats->stack_reuses =
        atomic_load_explicit(&global_scheduler_stats.stack_reuses,
            memory_order_relaxed);
    stats->work_steals =
        atomic_load_explicit(&global_scheduler_stats.work_steals,
            memory_order_relaxed);
    stats->run_queue_lock_contentions =
        atomic_load_explicit(
            &global_scheduler_stats.run_queue_lock_contentions,
            memory_order_relaxed);
    stats->timer_lock_contentions =
        atomic_load_explicit(&global_scheduler_stats.timer_lock_contentions,
            memory_order_relaxed);
    stats->worker_count =
        __blorp_pool ? __blorp_pool->num_threads : 0;
    stats->runnable_count =
        atomic_load_explicit(&__fiber_runnable_count, memory_order_relaxed);
    if (__fibers_initialized) {
        pthread_mutex_lock(&__fiber_timer_queue.lock);
        stats->timers_pending = (long)__fiber_timer_queue.len;
        pthread_mutex_unlock(&__fiber_timer_queue.lock);
    } else {
        stats->timers_pending = 0;
    }
    return stats;
}

void blorp_reset_scheduler_stats(void) {
    atomic_store_explicit(
        &__blorp_scheduler_stats_enabled, 1, memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.tasks_spawned, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fibers_created, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fibers_reused, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fibers_completed, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fiber_resumes, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fiber_parks, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.fiber_schedule_transitions,
        0, memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.runnable_enqueues, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.run_queue_pops, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.timer_inserts, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.timer_expirations, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.reactor_control_wakes, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.reactor_poll_wakes, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.reactor_ready_events, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.reactor_waiter_wakes, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.stack_allocations, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.stack_reuses, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.work_steals, 0,
        memory_order_relaxed);
    atomic_store_explicit(
        &global_scheduler_stats.run_queue_lock_contentions, 0,
        memory_order_relaxed);
    atomic_store_explicit(&global_scheduler_stats.timer_lock_contentions, 0,
        memory_order_relaxed);
}

// ============================================================================
// Function Profiling
// ============================================================================

#define BLORP_PROFILE_MAX_FUNCS 1024
#define BLORP_PROFILE_MAX_STACK 4096
#define BLORP_PROFILE_TLS_CACHE 128

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define BLORP_THREAD_LOCAL _Thread_local
#elif defined(_MSC_VER)
#define BLORP_THREAD_LOCAL __declspec(thread)
#else
#define BLORP_THREAD_LOCAL __thread
#endif

typedef struct blorp_ProfileEntry {
    const char* name;
    atomic_long total_ns;      // Total time in nanoseconds
    atomic_long call_count;
} blorp_ProfileEntry;

typedef struct {
    blorp_ProfileEntry* entry;
    long start_ns;
} blorp_ProfileFrame;

typedef struct {
    const char* name;
    blorp_ProfileEntry* entry;
} blorp_ProfileCacheEntry;

typedef struct {
    const char* name;
    long total_ns;
    long call_count;
} blorp_ProfileSnapshot;

static blorp_ProfileEntry profile_entries[BLORP_PROFILE_MAX_FUNCS];
static atomic_int profile_count = 0;
static atomic_int profiling_enabled = 0;
static atomic_int profile_reported = 0;
static atomic_int profile_termination_signal = 0;
static pthread_mutex_t profile_mutex = PTHREAD_MUTEX_INITIALIZER;
static BLORP_THREAD_LOCAL blorp_ProfileFrame profile_stack[BLORP_PROFILE_MAX_STACK];
static BLORP_THREAD_LOCAL int profile_stack_depth = 0;
static BLORP_THREAD_LOCAL blorp_ProfileCacheEntry profile_cache[BLORP_PROFILE_TLS_CACHE];

// Get current time in nanoseconds
static long blorp_profile_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000L + ts.tv_nsec;
}

// Find or create profile entry for a function. Caller must hold profile_mutex.
static blorp_ProfileEntry* blorp_profile_get_locked(const char* name, bool create) {
    // Linear search (good enough for small number of functions)
    int count = atomic_load(&profile_count);
    for (int i = 0; i < count; i++) {
        if (strcmp(profile_entries[i].name, name) == 0) {
            return &profile_entries[i];
        }
    }
    if (!create) return NULL;
    // Create new entry
    if (count < BLORP_PROFILE_MAX_FUNCS) {
        int index = count;
        blorp_ProfileEntry* entry = &profile_entries[index];
        entry->name = name;
        atomic_store(&entry->total_ns, 0);
        atomic_store(&entry->call_count, 0);
        atomic_store(&profile_count, index + 1);
        return entry;
    }
    return NULL;  // Too many functions
}

static inline blorp_ProfileEntry* blorp_profile_lookup_cached(const char* name) {
    uintptr_t slot = (((uintptr_t)name) >> 4) % BLORP_PROFILE_TLS_CACHE;
    blorp_ProfileCacheEntry* cached = &profile_cache[slot];
    if (cached->name == name) return cached->entry;

    pthread_mutex_lock(&profile_mutex);
    blorp_ProfileEntry* entry = blorp_profile_get_locked(name, true);
    pthread_mutex_unlock(&profile_mutex);

    cached->name = name;
    cached->entry = entry;
    return entry;
}

static void blorp_profile_signal_handler(int signum);
static void blorp_profile_maybe_terminate(void);

void blorp_profile_start(const char* func_name) {
    if (!atomic_load(&profiling_enabled)) return;

    blorp_profile_maybe_terminate();

    blorp_ProfileEntry* entry = blorp_profile_lookup_cached(func_name);
    if (!entry || profile_stack_depth >= BLORP_PROFILE_MAX_STACK) return;
    profile_stack[profile_stack_depth++] = (blorp_ProfileFrame) {
        .entry = entry,
        .start_ns = blorp_profile_now_ns()
    };
}

void blorp_profile_enable(void) {
    atomic_store(&profiling_enabled, 1);
    signal(SIGTERM, blorp_profile_signal_handler);
    signal(SIGINT, blorp_profile_signal_handler);
}

void blorp_profile_end(const char* func_name) {
    if (!atomic_load(&profiling_enabled)) return;
    long end_ns = blorp_profile_now_ns();

    int match_idx = -1;
    for (int i = profile_stack_depth - 1; i >= 0; i--) {
        const char* frame_name = profile_stack[i].entry->name;
        if (frame_name == func_name || strcmp(frame_name, func_name) == 0) {
            match_idx = i;
            break;
        }
    }
    if (match_idx < 0) return;

    blorp_ProfileEntry* entry = profile_stack[match_idx].entry;
    long elapsed_ns = end_ns - profile_stack[match_idx].start_ns;
    if (elapsed_ns < 0) elapsed_ns = 0;

    for (int i = match_idx; i < profile_stack_depth - 1; i++)
        profile_stack[i] = profile_stack[i + 1];
    profile_stack_depth--;

    atomic_fetch_add(&entry->total_ns, elapsed_ns);
    atomic_fetch_add(&entry->call_count, 1);
    blorp_profile_maybe_terminate();
}

// Comparison function for qsort (descending by total time)
static int profile_compare(const void* a, const void* b) {
    const blorp_ProfileSnapshot* ea = (const blorp_ProfileSnapshot*)a;
    const blorp_ProfileSnapshot* eb = (const blorp_ProfileSnapshot*)b;
    if (eb->total_ns > ea->total_ns) return 1;
    if (eb->total_ns < ea->total_ns) return -1;
    return 0;
}

void blorp_profile_report(void) {
    if (!atomic_load(&profiling_enabled)) return;
    if (atomic_exchange(&profile_reported, 1)) return;

    blorp_ProfileSnapshot entries[BLORP_PROFILE_MAX_FUNCS];
    int count = atomic_load(&profile_count);
    if (count == 0) {
        return;
    }
    for (int i = 0; i < count; i++) {
        entries[i].name = profile_entries[i].name;
        entries[i].total_ns = atomic_load(&profile_entries[i].total_ns);
        entries[i].call_count = atomic_load(&profile_entries[i].call_count);
    }

    // Sort by total time (descending)
    qsort(entries, count, sizeof(blorp_ProfileSnapshot), profile_compare);

    // Compute total time for percentage column
    long grand_total_ns = 0;
    for (int i = 0; i < count; i++)
        grand_total_ns += entries[i].total_ns;

    fprintf(stderr, "\n=== Function Profile ===\n");
    fprintf(stderr, "%-50s %10s %6s %10s %10s\n",
        "Function", "Time (ms)", "%", "Calls", "Avg (us)");
    fprintf(stderr, "%-50s %10s %6s %10s %10s\n",
        "--------------------------------------------------",
        "----------", "------", "----------", "----------");

    for (int i = 0; i < count; i++) {
        blorp_ProfileSnapshot* e = &entries[i];
        if (e->call_count > 0) {
            double total_ms = e->total_ns / 1000000.0;
            double pct = grand_total_ns > 0
                ? (e->total_ns * 100.0 / grand_total_ns) : 0.0;
            double avg_us = (e->total_ns / 1000.0) / e->call_count;
            fprintf(stderr, "%-50s %10.3f %5.1f%% %10ld %10.3f\n",
                e->name, total_ms, pct, e->call_count, avg_us);
        }
    }
    fprintf(stderr, "%-50s %10.3f\n", "TOTAL", grand_total_ns / 1000000.0);
    fprintf(stderr, "\n");

    // Collapsed stack format for flame graph tools
    // Usage: ./blorp run --profile prog.brp 2>profile.txt
    //        grep FLAME: profile.txt | sed 's/FLAME://' > collapsed.txt
    //        flamegraph.pl collapsed.txt > profile.svg
    for (int i = 0; i < count; i++) {
        blorp_ProfileSnapshot* e = &entries[i];
        if (e->call_count > 0 && e->total_ns > 0)
            fprintf(stderr, "FLAME:%s %ld\n", e->name, e->total_ns / 1000);
    }
}

static void blorp_profile_signal_handler(int signum) {
    atomic_store(&profile_termination_signal, signum);
}

static void blorp_profile_maybe_terminate(void) {
    int signum = atomic_exchange(&profile_termination_signal, 0);
    if (signum == 0) return;

    blorp_profile_report();
    signal(signum, SIG_DFL);
    raise(signum);
    _Exit(128 + signum);
}

// ============================================================================
// Debug Functions
// ============================================================================

static int blorp_debug_log_level = 0;

void blorp_debug_log_msg(blorp_String* s) {
    if (s && s->len > 0) fwrite(s->data, 1, s->len, stderr);
    fputc('\n', stderr);
}

static void blorp_debug_log(const char* level, blorp_String* msg) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    fprintf(stderr, "[%04d-%02d-%02d %02d:%02d:%02d.%03ld] %s: ",
        tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec/1000000, level);
    if (msg && msg->len > 0) fwrite(msg->data, 1, msg->len, stderr);
    fputc('\n', stderr);
}

void blorp_debug_info(blorp_String* s)  { if (blorp_debug_log_level <= 1) blorp_debug_log("INFO", s); }
void blorp_debug_warn(blorp_String* s)  { if (blorp_debug_log_level <= 2) blorp_debug_log("WARN", s); }
void blorp_debug_error(blorp_String* s) { if (blorp_debug_log_level <= 3) blorp_debug_log("ERROR", s); }
void blorp_debug_set_log_level(long level) { blorp_debug_log_level = (int)level; }

// ============================================================================
// Filesystem Operations
// ============================================================================

blorp_String* blorp_getcwd(void) {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) {
        return blorp_string_create(buf);
    }
    return blorp_string_create("");
}

long blorp_mkdir(const blorp_String* path) {
    if (!path || path->len == 0) return 0;
    char* tmp = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(tmp, path->data, path->len);
    tmp[path->len] = '\0';
    long result = mkdir(tmp, 0755) == 0 ? 1 : 0;
    free(tmp);
    return result;
}

long blorp_remove_file(const blorp_String* path) {
    if (!path || path->len == 0) return 0;
    char* tmp = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(tmp, path->data, path->len);
    tmp[path->len] = '\0';
    long result = unlink(tmp) == 0 ? 1 : 0;
    free(tmp);
    return result;
}

long blorp_remove_dir(const blorp_String* path) {
    if (!path || path->len == 0) return 0;
    char* tmp = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(tmp, path->data, path->len);
    tmp[path->len] = '\0';
    long result = rmdir(tmp) == 0 ? 1 : 0;
    free(tmp);
    return result;
}

long blorp_rename(const blorp_String* from, const blorp_String* to) {
    if (!from || from->len == 0 || !to || to->len == 0) return 0;
    char* f = (char*)blorp_malloc_checked(from->len + 1);
    char* t = (char*)blorp_malloc_checked(to->len + 1);
    memcpy(f, from->data, from->len); f[from->len] = '\0';
    memcpy(t, to->data, to->len); t[to->len] = '\0';
    long result = rename(f, t) == 0 ? 1 : 0;
    free(f);
    free(t);
    return result;
}

// File metadata
#include <sys/stat.h>

void* blorp_file_size(const blorp_String* path) {
    if (!path || path->len == 0) return (void*)blorp_result_err((void*)blorp_string_literal("empty path"));
    char* tmp = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(tmp, path->data, path->len);
    tmp[path->len] = '\0';
    struct stat st;
    if (stat(tmp, &st) != 0) {
        free(tmp);
        return (void*)blorp_result_err((void*)blorp_string_literal("file not found"));
    }
    free(tmp);
    return (void*)blorp_result_ok((void*)(long)st.st_size);
}

void* blorp_file_modified(const blorp_String* path) {
    if (!path || path->len == 0) return (void*)blorp_result_err((void*)blorp_string_literal("empty path"));
    char* tmp = (char*)blorp_malloc_checked(path->len + 1);
    memcpy(tmp, path->data, path->len);
    tmp[path->len] = '\0';
    struct stat st;
    if (stat(tmp, &st) != 0) {
        free(tmp);
        return (void*)blorp_result_err((void*)blorp_string_literal("file not found"));
    }
    free(tmp);
    // Return modification time as seconds since epoch
    long mtime = (long)st.st_mtime;
    return (void*)blorp_result_ok((void*)mtime);
}

blorp_String* blorp_temp_dir(void) {
    const char* tmp = getenv("TMPDIR");
    if (!tmp) tmp = "/tmp";
    return blorp_string_literal(tmp);
}

void* blorp_mkstemp_path(const blorp_String* prefix) {
    const char* tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    size_t plen = prefix ? prefix->len : 0;
    size_t tlen = strlen(tmpdir);
    // template: <tmpdir>/<prefix>XXXXXX
    size_t total = tlen + 1 + plen + 6 + 1;
    char* tmpl = (char*)blorp_malloc_checked(total);
    memcpy(tmpl, tmpdir, tlen);
    tmpl[tlen] = '/';
    if (plen > 0) memcpy(tmpl + tlen + 1, prefix->data, plen);
    memcpy(tmpl + tlen + 1 + plen, "XXXXXX", 6);
    tmpl[total - 1] = '\0';
    int fd = mkstemp(tmpl);
    if (fd < 0) {
        free(tmpl);
        return (void*)blorp_result_err((void*)blorp_string_literal("mkstemp failed"));
    }
    close(fd);
    blorp_String* path = blorp_string_literal(tmpl);
    free(tmpl);
    blorp_Result* res = blorp_result_ok((void*)path);
    res->release_mask = 1UL;
    return (void*)res;
}

// (removed blorp_walk_dir — now IR intrinsic)

void* blorp_exec_output(const blorp_String* cmd) {
    if (!cmd || cmd->len == 0) {
        blorp_String* err = blorp_string_literal("empty command");
        return (void*)blorp_result_err((void*)err);
    }
    char* tmp = (char*)blorp_malloc_checked(cmd->len + 1);
    memcpy(tmp, cmd->data, cmd->len);
    tmp[cmd->len] = '\0';
    FILE* fp = popen(tmp, "r");
    if (!fp) {
        free(tmp);
        blorp_String* err = blorp_string_literal("popen failed");
        return (void*)blorp_result_err((void*)err);
    }
    free(tmp);
    size_t cap = 4096, len = 0;
    char* buf = (char*)malloc(cap);
    if (!buf) { pclose(fp); return (void*)blorp_result_err((void*)blorp_string_literal("out of memory")); }
    size_t n;
    while ((n = fread(buf + len, 1, cap - len, fp)) > 0) {
        len += n;
        if (len == cap) {
            if (cap > SIZE_MAX / 2) break;
            cap *= 2;
            char* nb = (char*)realloc(buf, cap);
            if (!nb) break;
            buf = nb;
        }
    }
    int status = pclose(fp);
    if (status != 0) {
        free(buf);
        blorp_String* err = blorp_string_literal("command failed");
        return (void*)blorp_result_err((void*)err);
    }
    // Strip trailing newline
    if (len > 0 && buf[len-1] == '\n') len--;
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    if (len > 0) memcpy(result->data, buf, len);
    result->data[len] = '\0';
    free(buf);
    blorp_Result* res = blorp_result_ok((void*)result);
    res->release_mask = 1UL;
    return (void*)res;
}

// Process spawning with pipe capture
#include <spawn.h>
extern char **environ;

static blorp_String* __read_fd_to_string(int fd) {
    size_t cap = 4096, len = 0;
    char* buf = (char*)malloc(cap);
    if (!buf) return blorp_string_literal("");
    ssize_t n;
    while ((n = read(fd, buf + len, cap - len)) > 0) {
        len += (size_t)n;
        if (len == cap) {
            if (cap > SIZE_MAX / 2) break;
            cap *= 2;
            char* nb = (char*)realloc(buf, cap);
            if (!nb) break;
            buf = nb;
        }
    }
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + len + 1);
    result->len = len;
    result->capacity = len;
    if (len > 0) memcpy(result->data, buf, len);
    result->data[len] = '\0';
    free(buf);
    return result;
}

// Returns Result[Tuple3[String, String, Int], String]
// Tuple: (stdout, stderr, exit_code)
void* blorp_process_run(const blorp_String* program, const blorp_List* args) {
    if (!program || program->len == 0) {
        return (void*)blorp_result_err((void*)blorp_string_literal("empty program"));
    }

    // Build argv: [program, arg1, ..., NULL]
    long argc = args ? args->len : 0;
    char** argv = (char**)malloc(sizeof(char*) * (argc + 2));
    if (!argv) return (void*)blorp_result_err((void*)blorp_string_literal("out of memory"));

    // program name
    char* prog = (char*)malloc(program->len + 1);
    memcpy(prog, program->data, program->len);
    prog[program->len] = '\0';
    argv[0] = prog;

    for (long i = 0; i < argc; i++) {
        blorp_String* s = (blorp_String*)blorp_list_get((blorp_List*)args, i);
        char* a = (char*)malloc(s->len + 1);
        memcpy(a, s->data, s->len);
        a[s->len] = '\0';
        argv[i + 1] = a;
    }
    argv[argc + 1] = NULL;

    // Create pipes for stdout and stderr
    int stdout_pipe[2], stderr_pipe[2];
    if (pipe(stdout_pipe) != 0 || pipe(stderr_pipe) != 0) {
        for (long i = 0; i <= argc; i++) free(argv[i]);
        free(argv);
        return (void*)blorp_result_err((void*)blorp_string_literal("pipe failed"));
    }

    // Setup posix_spawn file actions
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
    posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);

    pid_t pid;
    int err = posix_spawnp(&pid, prog, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);

    // Close write ends in parent
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    if (err != 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        for (long i = 0; i <= argc; i++) free(argv[i]);
        free(argv);
        return (void*)blorp_result_err((void*)blorp_string_literal("spawn failed"));
    }

    // Read stdout and stderr
    blorp_String* out_str = __read_fd_to_string(stdout_pipe[0]);
    blorp_String* err_str = __read_fd_to_string(stderr_pipe[0]);
    close(stdout_pipe[0]);
    close(stderr_pipe[0]);

    // Wait for child
    int status;
    waitpid(pid, &status, 0);
    long exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    for (long i = 0; i <= argc; i++) free(argv[i]);
    free(argv);

    // Return (stdout, stderr, exit_code) tuple
    blorp_Tuple* t = blorp_tuple_new(3, (void*)out_str, (void*)err_str, (void*)(long)exit_code);
    blorp_tuple_set_rc(t, 0x3); // release_mask = 0b011 (first two are strings)
    blorp_Result* res = blorp_result_ok((void*)t);
    res->release_mask = 1UL;
    return (void*)res;
}

// Shell convenience: run via /bin/sh -c
void* blorp_process_shell(const blorp_String* command) {
    blorp_String* sh = blorp_string_literal("/bin/sh");
    blorp_String* flag = blorp_string_literal("-c");
    blorp_List* args = blorp_list_new(2);
    args = blorp_list_append(args, (void*)flag);
    args = blorp_list_append(args, (void*)command);
    void* result = blorp_process_run(sh, args);
    blorp_release((void*)sh);
    blorp_release((void*)flag);
    blorp_release((void*)args);
    return result;
}

// ============================================================================
// Hashing Functions
// ============================================================================

// Seeded FNV-1a hash for strings
long blorp_hash(blorp_String* s) {
    uint64_t h = 14695981039346656037ULL ^ __blorp_hash_seed;
    if (s) {
        for (long i = 0; i < s->len; i++) {
            h ^= (uint8_t)s->data[i];
            h *= 1099511628211ULL;
        }
    }
    return (long)h;
}

// FNV-1a hash for raw bytes
long blorp_hash_bytes(blorp_String* b) {
    return blorp_hash(b);
}

// SHA-256
static void blorp_sha256_transform(uint32_t state[8], const uint8_t block[64]) {
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    };
    uint32_t w[64], a, b, c, d, e, f, g, h;
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)block[i*4]<<24)|((uint32_t)block[i*4+1]<<16)|((uint32_t)block[i*4+2]<<8)|block[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ((w[i-15]>>7)|(w[i-15]<<25)) ^ ((w[i-15]>>18)|(w[i-15]<<14)) ^ (w[i-15]>>3);
        uint32_t s1 = ((w[i-2]>>17)|(w[i-2]<<15)) ^ ((w[i-2]>>19)|(w[i-2]<<13)) ^ (w[i-2]>>10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a=state[0]; b=state[1]; c=state[2]; d=state[3];
    e=state[4]; f=state[5]; g=state[6]; h=state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ((e>>6)|(e<<26)) ^ ((e>>11)|(e<<21)) ^ ((e>>25)|(e<<7));
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + k[i] + w[i];
        uint32_t S0 = ((a>>2)|(a<<30)) ^ ((a>>13)|(a<<19)) ^ ((a>>22)|(a<<10));
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}

blorp_String* blorp_sha256(blorp_String* s) {
    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    const uint8_t* data = s ? (const uint8_t*)s->data : NULL;
    uint64_t len = s ? (uint64_t)s->len : 0;
    uint64_t bits = len * 8;
    uint64_t pos = 0;
    uint8_t block[64];
    while (pos + 64 <= len) {
        blorp_sha256_transform(state, data + pos);
        pos += 64;
    }
    size_t rem = (size_t)(len - pos);
    memset(block, 0, 64);
    if (rem > 0) memcpy(block, data + pos, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        blorp_sha256_transform(state, block);
        memset(block, 0, 64);
    }
    for (int i = 0; i < 8; i++) block[63-i] = (uint8_t)(bits >> (i*8));
    blorp_sha256_transform(state, block);
    // Convert to hex string (64 chars)
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 65);
    result->len = 64;
    result->capacity = 64;
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 4; j++) {
            uint8_t byte = (state[i] >> (24 - j*8)) & 0xff;
            result->data[i*8+j*2] = hex[byte >> 4];
            result->data[i*8+j*2+1] = hex[byte & 0xf];
        }
    }
    result->data[64] = '\0';
    return result;
}

// MD5
static void blorp_md5_transform(uint32_t state[4], const uint8_t block[64]) {
    static const uint32_t k[64] = {
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391
    };
    static const int s[64] = {
        7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
        5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,
        4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
        6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
    };
    uint32_t m[16];
    for (int i = 0; i < 16; i++)
        m[i] = ((uint32_t)block[i*4])|((uint32_t)block[i*4+1]<<8)|((uint32_t)block[i*4+2]<<16)|((uint32_t)block[i*4+3]<<24);
    uint32_t a=state[0], b=state[1], c=state[2], d=state[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f, g;
        if (i < 16) { f = (b & c) | (~b & d); g = i; }
        else if (i < 32) { f = (d & b) | (~d & c); g = (5*i+1) % 16; }
        else if (i < 48) { f = b ^ c ^ d; g = (3*i+5) % 16; }
        else { f = c ^ (b | ~d); g = (7*i) % 16; }
        uint32_t temp = d;
        d = c; c = b;
        uint32_t x = a + f + k[i] + m[g];
        b = b + ((x << s[i]) | (x >> (32 - s[i])));
        a = temp;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
}

blorp_String* blorp_md5(blorp_String* s) {
    uint32_t state[4] = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 };
    const uint8_t* data = s ? (const uint8_t*)s->data : NULL;
    uint64_t len = s ? (uint64_t)s->len : 0;
    uint64_t bits = len * 8;
    uint64_t pos = 0;
    uint8_t block[64];
    while (pos + 64 <= len) {
        blorp_md5_transform(state, data + pos);
        pos += 64;
    }
    size_t rem = (size_t)(len - pos);
    memset(block, 0, 64);
    if (rem > 0) memcpy(block, data + pos, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        blorp_md5_transform(state, block);
        memset(block, 0, 64);
    }
    // MD5 uses little-endian bit length
    for (int i = 0; i < 8; i++) block[56+i] = (uint8_t)(bits >> (i*8));
    blorp_md5_transform(state, block);
    // Convert to hex string (32 chars) - MD5 is little-endian
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 33);
    result->len = 32;
    result->capacity = 32;
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            uint8_t byte = (state[i] >> (j*8)) & 0xff;
            result->data[i*8+j*2] = hex[byte >> 4];
            result->data[i*8+j*2+1] = hex[byte & 0xf];
        }
    }
    result->data[32] = '\0';
    return result;
}

// SHA-1
static void blorp_sha1_transform(uint32_t state[5], const uint8_t block[64]) {
    uint32_t w[80], a, b, c, d, e;
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)block[i*4]<<24)|((uint32_t)block[i*4+1]<<16)|((uint32_t)block[i*4+2]<<8)|block[i*4+3];
    for (int i = 16; i < 80; i++) {
        uint32_t x = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
        w[i] = (x << 1) | (x >> 31);
    }
    a=state[0]; b=state[1]; c=state[2]; d=state[3]; e=state[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20)      { f = (b & c) | (~b & d); k = 0x5a827999; }
        else if (i < 40) { f = b ^ c ^ d;           k = 0x6ed9eba1; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc; }
        else              { f = b ^ c ^ d;           k = 0xca62c1d6; }
        uint32_t temp = ((a<<5)|(a>>27)) + f + e + k + w[i];
        e = d; d = c; c = (b<<30)|(b>>2); b = a; a = temp;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d; state[4]+=e;
}

blorp_String* blorp_sha1(blorp_String* s) {
    uint32_t state[5] = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
    const uint8_t* data = s ? (const uint8_t*)s->data : NULL;
    uint64_t len = s ? (uint64_t)s->len : 0;
    uint64_t bits = len * 8;
    uint64_t pos = 0;
    uint8_t block[64];
    while (pos + 64 <= len) {
        blorp_sha1_transform(state, data + pos);
        pos += 64;
    }
    size_t rem = (size_t)(len - pos);
    memset(block, 0, 64);
    if (rem > 0) memcpy(block, data + pos, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        blorp_sha1_transform(state, block);
        memset(block, 0, 64);
    }
    for (int i = 0; i < 8; i++) block[63-i] = (uint8_t)(bits >> (i*8));
    blorp_sha1_transform(state, block);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 41);
    result->len = 40;
    result->capacity = 40;
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 4; j++) {
            uint8_t byte = (state[i] >> (24 - j*8)) & 0xff;
            result->data[i*8+j*2] = hex[byte >> 4];
            result->data[i*8+j*2+1] = hex[byte & 0xf];
        }
    }
    result->data[40] = '\0';
    return result;
}

// SHA-512
static void blorp_sha512_transform(uint64_t state[8], const uint8_t block[128]) {
    static const uint64_t k[80] = {
        0x428a2f98d728ae22ULL,0x7137449123ef65cdULL,0xb5c0fbcfec4d3b2fULL,0xe9b5dba58189dbbcULL,
        0x3956c25bf348b538ULL,0x59f111f1b605d019ULL,0x923f82a4af194f9bULL,0xab1c5ed5da6d8118ULL,
        0xd807aa98a3030242ULL,0x12835b0145706fbeULL,0x243185be4ee4b28cULL,0x550c7dc3d5ffb4e2ULL,
        0x72be5d74f27b896fULL,0x80deb1fe3b1696b1ULL,0x9bdc06a725c71235ULL,0xc19bf174cf692694ULL,
        0xe49b69c19ef14ad2ULL,0xefbe4786384f25e3ULL,0x0fc19dc68b8cd5b5ULL,0x240ca1cc77ac9c65ULL,
        0x2de92c6f592b0275ULL,0x4a7484aa6ea6e483ULL,0x5cb0a9dcbd41fbd4ULL,0x76f988da831153b5ULL,
        0x983e5152ee66dfabULL,0xa831c66d2db43210ULL,0xb00327c898fb213fULL,0xbf597fc7beef0ee4ULL,
        0xc6e00bf33da88fc2ULL,0xd5a79147930aa725ULL,0x06ca6351e003826fULL,0x142929670a0e6e70ULL,
        0x27b70a8546d22ffcULL,0x2e1b21385c26c926ULL,0x4d2c6dfc5ac42aedULL,0x53380d139d95b3dfULL,
        0x650a73548baf63deULL,0x766a0abb3c77b2a8ULL,0x81c2c92e47edaee6ULL,0x92722c851482353bULL,
        0xa2bfe8a14cf10364ULL,0xa81a664bbc423001ULL,0xc24b8b70d0f89791ULL,0xc76c51a30654be30ULL,
        0xd192e819d6ef5218ULL,0xd69906245565a910ULL,0xf40e35855771202aULL,0x106aa07032bbd1b8ULL,
        0x19a4c116b8d2d0c8ULL,0x1e376c085141ab53ULL,0x2748774cdf8eeb99ULL,0x34b0bcb5e19b48a8ULL,
        0x391c0cb3c5c95a63ULL,0x4ed8aa4ae3418acbULL,0x5b9cca4f7763e373ULL,0x682e6ff3d6b2b8a3ULL,
        0x748f82ee5defb2fcULL,0x78a5636f43172f60ULL,0x84c87814a1f0ab72ULL,0x8cc702081a6439ecULL,
        0x90befffa23631e28ULL,0xa4506cebde82bde9ULL,0xbef9a3f7b2c67915ULL,0xc67178f2e372532bULL,
        0xca273eceea26619cULL,0xd186b8c721c0c207ULL,0xeada7dd6cde0eb1eULL,0xf57d4f7fee6ed178ULL,
        0x06f067aa72176fbaULL,0x0a637dc5a2c898a6ULL,0x113f9804bef90daeULL,0x1b710b35131c471bULL,
        0x28db77f523047d84ULL,0x32caab7b40c72493ULL,0x3c9ebe0a15c9bebcULL,0x431d67c49c100d4cULL,
        0x4cc5d4becb3e42b6ULL,0x597f299cfc657e2aULL,0x5fcb6fab3ad6faecULL,0x6c44198c4a475817ULL
    };
    uint64_t w[80], a, b, c, d, e, f, g, h;
    for (int i = 0; i < 16; i++)
        w[i] = ((uint64_t)block[i*8]<<56)|((uint64_t)block[i*8+1]<<48)|((uint64_t)block[i*8+2]<<40)|
               ((uint64_t)block[i*8+3]<<32)|((uint64_t)block[i*8+4]<<24)|((uint64_t)block[i*8+5]<<16)|
               ((uint64_t)block[i*8+6]<<8)|block[i*8+7];
    for (int i = 16; i < 80; i++) {
        uint64_t s0 = ((w[i-15]>>1)|(w[i-15]<<63)) ^ ((w[i-15]>>8)|(w[i-15]<<56)) ^ (w[i-15]>>7);
        uint64_t s1 = ((w[i-2]>>19)|(w[i-2]<<45)) ^ ((w[i-2]>>61)|(w[i-2]<<3)) ^ (w[i-2]>>6);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a=state[0]; b=state[1]; c=state[2]; d=state[3];
    e=state[4]; f=state[5]; g=state[6]; h=state[7];
    for (int i = 0; i < 80; i++) {
        uint64_t S1 = ((e>>14)|(e<<50)) ^ ((e>>18)|(e<<46)) ^ ((e>>41)|(e<<23));
        uint64_t ch = (e & f) ^ (~e & g);
        uint64_t t1 = h + S1 + ch + k[i] + w[i];
        uint64_t S0 = ((a>>28)|(a<<36)) ^ ((a>>34)|(a<<30)) ^ ((a>>39)|(a<<25));
        uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint64_t t2 = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}

blorp_String* blorp_sha512(blorp_String* s) {
    uint64_t state[8] = {
        0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
        0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
        0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
    };
    const uint8_t* data = s ? (const uint8_t*)s->data : NULL;
    uint64_t len = s ? (uint64_t)s->len : 0;
    __uint128_t bits = (__uint128_t)len * 8;
    uint64_t pos = 0;
    uint8_t block[128];
    while (pos + 128 <= len) {
        blorp_sha512_transform(state, data + pos);
        pos += 128;
    }
    size_t rem = (size_t)(len - pos);
    memset(block, 0, 128);
    if (rem > 0) memcpy(block, data + pos, rem);
    block[rem] = 0x80;
    if (rem >= 112) {
        blorp_sha512_transform(state, block);
        memset(block, 0, 128);
    }
    for (int i = 0; i < 16; i++) block[127-i] = (uint8_t)(bits >> (i*8));
    blorp_sha512_transform(state, block);
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 129);
    result->len = 128;
    result->capacity = 128;
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) {
            uint8_t byte = (state[i] >> (56 - j*8)) & 0xff;
            result->data[i*16+j*2] = hex[byte >> 4];
            result->data[i*16+j*2+1] = hex[byte & 0xf];
        }
    }
    result->data[128] = '\0';
    return result;
}

// CRC32 (IEEE 802.3)
static uint32_t blorp_crc32_table[256];
static int blorp_crc32_table_init = 0;
static void blorp_crc32_init(void) {
    if (blorp_crc32_table_init) return;
    for (int i = 0; i < 256; i++) {
        uint32_t crc = (uint32_t)i;
        for (int j = 0; j < 8; j++)
            crc = (crc >> 1) ^ (0xEDB88320 & (-(crc & 1)));
        blorp_crc32_table[i] = crc;
    }
    blorp_crc32_table_init = 1;
}

long blorp_crc32(blorp_String* s) {
    blorp_crc32_init();
    uint32_t crc = 0xffffffff;
    if (s) {
        for (long i = 0; i < s->len; i++)
            crc = blorp_crc32_table[(crc ^ (uint8_t)s->data[i]) & 0xff] ^ (crc >> 8);
    }
    return (long)(crc ^ 0xffffffff);
}

// _bytes variants (Bytes is same struct as String)
blorp_String* blorp_sha256_bytes(blorp_String* b) { return blorp_sha256(b); }
blorp_String* blorp_md5_bytes(blorp_String* b)    { return blorp_md5(b); }
blorp_String* blorp_sha1_bytes(blorp_String* b)   { return blorp_sha1(b); }
blorp_String* blorp_sha512_bytes(blorp_String* b) { return blorp_sha512(b); }
long blorp_crc32_bytes(blorp_String* b)            { return blorp_crc32(b); }

// HMAC-SHA256
// Internal: raw SHA-256 that returns 32 bytes into caller buffer
static void blorp_sha256_raw(const uint8_t* data, uint64_t len, uint8_t out[32]) {
    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };
    uint64_t bits = len * 8;
    uint64_t pos = 0;
    uint8_t block[64];
    while (pos + 64 <= len) {
        blorp_sha256_transform(state, data + pos);
        pos += 64;
    }
    size_t rem = (size_t)(len - pos);
    memset(block, 0, 64);
    if (rem > 0) memcpy(block, data + pos, rem);
    block[rem] = 0x80;
    if (rem >= 56) {
        blorp_sha256_transform(state, block);
        memset(block, 0, 64);
    }
    for (int i = 0; i < 8; i++) block[63-i] = (uint8_t)(bits >> (i*8));
    blorp_sha256_transform(state, block);
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (state[i] >> 24) & 0xff;
        out[i*4+1] = (state[i] >> 16) & 0xff;
        out[i*4+2] = (state[i] >>  8) & 0xff;
        out[i*4+3] =  state[i]        & 0xff;
    }
}

blorp_String* blorp_hmac_sha256(blorp_String* key, blorp_String* msg) {
    uint8_t k_pad[64];
    memset(k_pad, 0, 64);
    const uint8_t* key_data = key ? (const uint8_t*)key->data : NULL;
    long key_len = key ? key->len : 0;
    if (key_len > 64) {
        blorp_sha256_raw(key_data, (uint64_t)key_len, k_pad);
        // k_pad now has 32 bytes of hashed key, rest is 0
    } else {
        if (key_len > 0) memcpy(k_pad, key_data, (size_t)key_len);
    }
    // Inner hash: SHA-256(ipad || message)
    uint8_t i_key[64];
    for (int i = 0; i < 64; i++) i_key[i] = k_pad[i] ^ 0x36;
    const uint8_t* msg_data = msg ? (const uint8_t*)msg->data : NULL;
    long msg_len = msg ? msg->len : 0;
    uint64_t inner_len = 64 + (uint64_t)msg_len;
    uint8_t* inner_buf = (uint8_t*)blorp_malloc_checked(inner_len);
    memcpy(inner_buf, i_key, 64);
    if (msg_len > 0) memcpy(inner_buf + 64, msg_data, (size_t)msg_len);
    uint8_t inner_hash[32];
    blorp_sha256_raw(inner_buf, inner_len, inner_hash);
    free(inner_buf);
    // Outer hash: SHA-256(opad || inner_hash)
    uint8_t outer_buf[96]; // 64 + 32
    for (int i = 0; i < 64; i++) outer_buf[i] = k_pad[i] ^ 0x5c;
    memcpy(outer_buf + 64, inner_hash, 32);
    uint8_t final_hash[32];
    blorp_sha256_raw(outer_buf, 96, final_hash);
    // Convert to 64-char hex string
    blorp_String* result = (blorp_String*)blorp_alloc(sizeof(blorp_String) + 65);
    result->len = 64;
    result->capacity = 64;
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        result->data[i*2]   = hex[final_hash[i] >> 4];
        result->data[i*2+1] = hex[final_hash[i] & 0xf];
    }
    result->data[64] = '\0';
    return result;
}

// ============================================================================
// Signal Handling
// ============================================================================

#define BLORP_MAX_SIGNAL 32

static _Atomic(int) __blorp_sig_flags[BLORP_MAX_SIGNAL];
static void* __blorp_sig_closures[BLORP_MAX_SIGNAL];
static int __blorp_sig_pipe[2] = {-1, -1};
static _Atomic(int) __blorp_sig_initialized = 0;

// Signal handler (async-signal-safe — only atomic store + write)
static void __blorp_sig_handler(int signum) {
    if (signum >= 0 && signum < BLORP_MAX_SIGNAL) {
        atomic_store_explicit(&__blorp_sig_flags[signum], 1, memory_order_relaxed);
        unsigned char c = (unsigned char)signum;
        (void)write(__blorp_sig_pipe[1], &c, 1);
    }
}

// Dispatcher thread — reads signal numbers from pipe, dispatches closures
static void* __blorp_sig_dispatcher(void* arg) {
    (void)arg;
    unsigned char c;
    while (1) {
        ssize_t n = read(__blorp_sig_pipe[0], &c, 1);
        if (n <= 0) break;
        int signum = (int)c;
        if (signum >= 0 && signum < BLORP_MAX_SIGNAL) {
            void* closure = __blorp_sig_closures[signum];
            if (closure) {
                blorp_retain(closure);
                blorp_detach(closure);
            }
        }
    }
    return NULL;
}

// Initialize signal dispatch system (once)
static void __blorp_sig_init(void) {
    int expected = 0;
    if (atomic_compare_exchange_strong(&__blorp_sig_initialized, &expected, 1)) {
        memset((void*)__blorp_sig_closures, 0, sizeof(__blorp_sig_closures));
        pipe(__blorp_sig_pipe);
        // Set pipe write end to non-blocking so signal handler never blocks
        int flags = fcntl(__blorp_sig_pipe[1], F_GETFL);
        fcntl(__blorp_sig_pipe[1], F_SETFL, flags | O_NONBLOCK);
        pthread_t thread;
        pthread_create(&thread, NULL, __blorp_sig_dispatcher, NULL);
        pthread_detach(thread);
    }
}

// Track which signals have handlers installed
static _Atomic(int) __blorp_sig_installed[BLORP_MAX_SIGNAL];

// Install the flag-setting handler for a signal (idempotent)
static void __blorp_sig_install(int signum) {
    if (signum < 1 || signum >= BLORP_MAX_SIGNAL) return;
    int expected = 0;
    if (atomic_compare_exchange_strong(&__blorp_sig_installed[signum], &expected, 1)) {
        __blorp_sig_init();
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = __blorp_sig_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(signum, &sa, NULL);
    }
}

// on_signal(signum, handler) -> Void
void blorp_signal_on(long signum, blorp_Closure* handler) {
    if (signum < 1 || signum >= BLORP_MAX_SIGNAL) return;
    __blorp_sig_install((int)signum);
    // Release old closure if any
    void* old = __blorp_sig_closures[signum];
    if (old) blorp_release(old);
    // Retain and store new closure
    if (handler) blorp_retain(handler);
    __blorp_sig_closures[signum] = handler;
}

// signal_received(signum) -> Bool  (checks and clears flag)
long blorp_signal_received(long signum) {
    if (signum < 0 || signum >= BLORP_MAX_SIGNAL) return 0;
    return (long)atomic_exchange_explicit(&__blorp_sig_flags[signum], 0, memory_order_relaxed);
}

// raise_signal(signum) -> Void  (send signal to own process, auto-installs handler)
void blorp_signal_raise(long signum) {
    __blorp_sig_install((int)signum);
    raise((int)signum);
}
