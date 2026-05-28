// ============================================================================
// blorp Runtime - Declarations Only (for precompiled runtime linking)
// ============================================================================
// This file provides type definitions, macros, static inline functions, and
// forward declarations for all runtime functions. It is used by the test runner
// to compile test code without re-compiling the full runtime.
//
// Usage: cc -DBLORP_RUNTIME_PRECOMPILED -o test test.c runtime.o -lm -lpthread
// The generated test.c includes this file instead of the full runtime.c.

#define _GNU_SOURCE  // Required for memmem() on Linux/glibc

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <setjmp.h>
#include <limits.h>
#include <math.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <signal.h>
#include <pthread.h>
#include <regex.h>

// ============================================================================
// SIMD Platform Detection and Abstractions
// ============================================================================

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
// SIMD Type Abstractions
// ============================================================================

#if defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
    typedef __m128  blorp_simd_f32x4;
    typedef __m128d blorp_simd_f64x2;
    typedef __m128i blorp_simd_i32x4;
    typedef __m128i blorp_simd_i64x2;

    #define BLORP_SIMD_LOAD_F32X4(ptr)      _mm_loadu_ps(ptr)
    #define BLORP_SIMD_STORE_F32X4(ptr, v)  _mm_storeu_ps(ptr, v)
    #define BLORP_SIMD_LOAD_F64X2(ptr)      _mm_loadu_pd(ptr)
    #define BLORP_SIMD_STORE_F64X2(ptr, v)  _mm_storeu_pd(ptr, v)
    #define BLORP_SIMD_LOAD_I32X4(ptr)      _mm_loadu_si128((const __m128i*)(ptr))
    #define BLORP_SIMD_STORE_I32X4(ptr, v)  _mm_storeu_si128((__m128i*)(ptr), v)

    #define BLORP_SIMD_ADD_F32X4(a, b)      _mm_add_ps(a, b)
    #define BLORP_SIMD_SUB_F32X4(a, b)      _mm_sub_ps(a, b)
    #define BLORP_SIMD_MUL_F32X4(a, b)      _mm_mul_ps(a, b)
    #define BLORP_SIMD_DIV_F32X4(a, b)      _mm_div_ps(a, b)

    #define BLORP_SIMD_ADD_F64X2(a, b)      _mm_add_pd(a, b)
    #define BLORP_SIMD_SUB_F64X2(a, b)      _mm_sub_pd(a, b)
    #define BLORP_SIMD_MUL_F64X2(a, b)      _mm_mul_pd(a, b)
    #define BLORP_SIMD_DIV_F64X2(a, b)      _mm_div_pd(a, b)

    #define BLORP_SIMD_ADD_I32X4(a, b)      _mm_add_epi32(a, b)
    #define BLORP_SIMD_SUB_I32X4(a, b)      _mm_sub_epi32(a, b)
    #if defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        #define BLORP_SIMD_MUL_I32X4(a, b)  _mm_mullo_epi32(a, b)
    #else
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

    #if defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        #define BLORP_SIMD_BLEND_F32X4(a, b, mask) _mm_blendv_ps(a, b, mask)
        #define BLORP_SIMD_BLEND_F64X2(a, b, mask) _mm_blendv_pd(a, b, mask)
    #else
        #define BLORP_SIMD_BLEND_F32X4(a, b, mask) \
            _mm_or_ps(_mm_and_ps(mask, b), _mm_andnot_ps(mask, a))
        #define BLORP_SIMD_BLEND_F64X2(a, b, mask) \
            _mm_or_pd(_mm_and_pd(mask, b), _mm_andnot_pd(mask, a))
    #endif

#elif defined(BLORP_SIMD_NEON)
    typedef float32x4_t blorp_simd_f32x4;
    typedef float64x2_t blorp_simd_f64x2;
    typedef int32x4_t   blorp_simd_i32x4;
    typedef int64x2_t   blorp_simd_i64x2;

    #define BLORP_SIMD_LOAD_F32X4(ptr)      vld1q_f32(ptr)
    #define BLORP_SIMD_STORE_F32X4(ptr, v)  vst1q_f32(ptr, v)
    #define BLORP_SIMD_LOAD_F64X2(ptr)      vld1q_f64(ptr)
    #define BLORP_SIMD_STORE_F64X2(ptr, v)  vst1q_f64(ptr, v)
    #define BLORP_SIMD_LOAD_I32X4(ptr)      vld1q_s32(ptr)
    #define BLORP_SIMD_STORE_I32X4(ptr, v)  vst1q_s32(ptr, v)

    #define BLORP_SIMD_ADD_F32X4(a, b)      vaddq_f32(a, b)
    #define BLORP_SIMD_SUB_F32X4(a, b)      vsubq_f32(a, b)
    #define BLORP_SIMD_MUL_F32X4(a, b)      vmulq_f32(a, b)
    #define BLORP_SIMD_DIV_F32X4(a, b)      vdivq_f32(a, b)

    #define BLORP_SIMD_ADD_F64X2(a, b)      vaddq_f64(a, b)
    #define BLORP_SIMD_SUB_F64X2(a, b)      vsubq_f64(a, b)
    #define BLORP_SIMD_MUL_F64X2(a, b)      vmulq_f64(a, b)
    #define BLORP_SIMD_DIV_F64X2(a, b)      vdivq_f64(a, b)

    #define BLORP_SIMD_ADD_I32X4(a, b)      vaddq_s32(a, b)
    #define BLORP_SIMD_SUB_I32X4(a, b)      vsubq_s32(a, b)
    #define BLORP_SIMD_MUL_I32X4(a, b)      vmulq_s32(a, b)

    #define BLORP_SIMD_BLEND_F32X4(a, b, mask) vbslq_f32(mask, b, a)
    #define BLORP_SIMD_BLEND_F64X2(a, b, mask) vbslq_f64(mask, b, a)

#else
    typedef struct { float v[4]; }  blorp_simd_f32x4;
    typedef struct { double v[2]; } blorp_simd_f64x2;
    typedef struct { int32_t v[4]; } blorp_simd_i32x4;
    typedef struct { int64_t v[2]; } blorp_simd_i64x2;

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

#endif

// ============================================================================
// Type Definitions (must match runtime.c exactly)
// ============================================================================

typedef struct blorp_Object_s {
    _Atomic long refcount;
    uint32_t alloc_class;
    uint32_t destructor_id;
} blorp_Object;

#define BLORP_ALLOC_CLASS_DIRECT UINT32_MAX
typedef void (*blorp_destructor_fn)(void*);

typedef struct {
    blorp_Object header;
    long total_allocations;
    long total_releases;
    long current_objects;
    long bytes_allocated;
} blorp_MemStats;

typedef struct {
    blorp_Object header;
    long tasks_spawned;
    long tasks_cancelled;
    long task_timeouts;
    long fibers_created;
    long fibers_reused;
    long fibers_completed;
    long fiber_resumes;
    long fiber_parks;
    long fiber_schedule_transitions;
    long channel_send_parks;
    long channel_recv_parks;
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
    long tracked_active_tasks;
    long tracked_parked_fibers;
    long worker_count;
    long runnable_count;
    long timers_pending;
} blorp_SchedulerStats;

typedef struct blorp_TcpListener blorp_TcpListener;
typedef struct blorp_TcpStream blorp_TcpStream;
typedef struct blorp_FileReader blorp_FileReader;
typedef struct blorp_FileWriter blorp_FileWriter;
typedef struct blorp_File blorp_File;
typedef struct blorp_Bytes blorp_Bytes;

typedef struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[5]; void* data[]; } blorp_Vector;
#define BLORP_VECTOR_STORAGE_POINTER 0
#define BLORP_VECTOR_STORAGE_INLINE 1
#define BLORP_VECTOR_STORAGE_F64 2
#define BLORP_VECTOR_STORAGE_F32 3
#define BLORP_VECTOR_STORAGE_PACKED 4
#define BLORP_VECTOR_STORAGE_I64 5

typedef struct { blorp_Object header; long len; long capacity; char data[]; } blorp_String;

typedef enum {
    BLORP_FILE_ERROR_NONE = 0,
    BLORP_FILE_ERROR_NOT_FOUND = 1,
    BLORP_FILE_ERROR_PERMISSION_DENIED = 2,
    BLORP_FILE_ERROR_ALREADY_EXISTS = 3,
    BLORP_FILE_ERROR_INVALID_INPUT = 4,
    BLORP_FILE_ERROR_INTERRUPTED = 5,
    BLORP_FILE_ERROR_TIMED_OUT = 6,
    BLORP_FILE_ERROR_UNSUPPORTED = 7,
    BLORP_FILE_ERROR_OTHER = 8
} blorp_FileErrorKind;

typedef struct {
    blorp_FileReader* handle;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileOpenReaderResult;

typedef struct {
    blorp_FileWriter* handle;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileOpenWriterResult;

typedef struct {
    blorp_File* handle;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileOpenResult;

typedef struct {
    blorp_String* value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileStringResult;

typedef struct {
    blorp_Bytes* value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileBytesResult;

typedef struct {
    void* value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileValueResult;

typedef struct {
    long found;
    void* value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileFindResult;

typedef struct {
    long value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileIntResult;

typedef struct {
    long value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileBoolResult;

typedef struct {
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileVoidResult;

#define BLORP_LIST_STORAGE_POINTER 0
#define BLORP_LIST_STORAGE_INLINE 1
#define BLORP_LIST_CALLBACK_BITS 0
#define BLORP_LIST_CALLBACK_BOXED_STRUCT 1
#define BLORP_VECTOR_CALLBACK_BITS 0
#define BLORP_VECTOR_CALLBACK_BOXED_STRUCT 1
#define BLORP_VECTOR_CALLBACK_BOXED_FLOAT 2
#define BLORP_VECTOR_CALLBACK_BOXED_FLOAT32 3
typedef struct { blorp_Object header; long len; long capacity; void (*elem_release)(void*); int16_t elem_size; uint8_t storage_mode; char __pad[5]; void* data[]; } blorp_List;

typedef struct {
    blorp_List* value;
    blorp_FileErrorKind error_kind;
    blorp_String* detail;
} blorp_FileListResult;

typedef struct {
    blorp_Object header;
    int tag;
    unsigned long release_mask;
    union {
        struct { void* field0; } Some;
        char None;
    } data;
} blorp_Option;

typedef struct {
    blorp_Object header;
    int tag;
    unsigned long release_mask;
    union {
        struct { void* field0; } Ok;
        struct { void* field0; } Err;
    } data;
} blorp_Result;

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

struct blorp_Bytes {
    blorp_Object header;
    long len;
    long capacity;
    unsigned char data[];
};

typedef struct { blorp_Object header; long arity; long release_mask; void* elem[]; } blorp_Tuple;

#define DICT_META_EMPTY   0xFF
#define DICT_META_DELETED 0x80
#define DICT_GROUP_SIZE   16

typedef struct {
    blorp_Object header;
    long size;
    long order_len;
    long capacity;
    long mask;
    long grow_at;
    void** keys;
    void** values;
    uint8_t* meta;
    long* order;
    long* order_index;
    unsigned long (*hash_fn)(void*);
    bool (*eq_fn)(void*, void*);
    void (*key_release)(void*);
    void (*value_release)(void*);
} blorp_Dict;

typedef struct blorp_SetEntry {
    void* key;
    struct blorp_SetEntry* next;
    struct blorp_SetEntry* prev_order;
    struct blorp_SetEntry* next_order;
} blorp_SetEntry;

typedef struct {
    blorp_Object header;
    long size;
    long capacity;
    long mask;
    blorp_SetEntry** buckets;
    blorp_SetEntry* first;
    blorp_SetEntry* last;
    unsigned long (*hash_fn)(void*);
    bool (*eq_fn)(void*, void*);
    void (*key_release)(void*);
} blorp_Set;

typedef struct blorp_Closure_s {
    blorp_Object header;
    void* func;
    void* env;
    long env_count;
    unsigned long env_release_mask;
} blorp_Closure;

typedef struct blorp_WorkItem_s {
    struct blorp_WorkItem_s* next;
    void (*func)(void* arg);
    void* arg;
} blorp_WorkItem;

typedef struct {
    pthread_t* threads;
    long num_threads;
    pthread_mutex_t queue_lock;
    pthread_cond_t queue_cond;
    blorp_WorkItem* queue_head;
    blorp_WorkItem* queue_tail;
    bool shutdown;
} blorp_ThreadPool;

typedef struct blorp_Fiber blorp_Fiber;  // forward decl for Task/Channel
typedef struct blorp_ChannelSelectWaiter blorp_ChannelSelectWaiter;
typedef struct {
    blorp_Fiber* runnable_head;
    blorp_Fiber* runnable_tail;
    long runnable_count;
} blorp_TaskBatch;
#define BLORP_TASK_BATCH_FLUSH_INTERVAL 256L
typedef void (*blorp_CancelCleanupFn)(void*);

typedef struct blorp_CancelCleanupFrame {
    struct blorp_CancelCleanupFrame* prev;
    const void* slot;
    void* value;
    blorp_CancelCleanupFn release_value;
    bool active;
} blorp_CancelCleanupFrame;

typedef struct blorp_Task_s {
    blorp_Object header;
    pthread_mutex_t mutex;
    pthread_cond_t done_cond;
    bool completed;
    bool joined;
    void* result;
    blorp_Closure* func;
    bool result_is_rc;
    blorp_Fiber* waiting_fiber;
    blorp_Fiber* task_fiber;
    jmp_buf cancel_jmp;
    bool cancel_jmp_ready;
    blorp_CancelCleanupFrame* cleanup_stack;
    _Atomic int cancelled;
} blorp_Task;

typedef struct {
    blorp_Object header;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
    void** buffer;
    long capacity, count, head, tail;
    bool sealed;
    void (*elem_release)(void*);
    blorp_Fiber* send_waiters_head;
    blorp_Fiber* send_waiters_tail;
    blorp_Fiber* recv_waiters_head;
    blorp_Fiber* recv_waiters_tail;
    blorp_ChannelSelectWaiter* select_waiters_head;
    blorp_ChannelSelectWaiter* select_waiters_tail;
} blorp_Channel;

typedef struct {
    blorp_Object header;
    long value;
    int scale;
    int precision;
} blorp_Fixed;

typedef struct {
    blorp_Object header;
    blorp_String* source;
    long start;
    long len;
} blorp_StringSlice;

// ============================================================================
// Key Macros (used by codegen)
// ============================================================================

#define BLORP_IMMORTAL_REFCOUNT LONG_MAX
#define BLORP_TAG_SOME 0
#define BLORP_TAG_NONE 1

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
#define BLORP_TAG_OK 0
#define BLORP_TAG_ERR 1
#define TAG_ConcurrencyError_Timeout 0
#define TAG_ConcurrencyError_TaskFailed 1
#define TAG_ConcurrencyError_Cancelled 2
#define TAG_Timeout TAG_ConcurrencyError_Timeout
#define TAG_TaskFailed TAG_ConcurrencyError_TaskFailed
#define TAG_Cancelled TAG_ConcurrencyError_Cancelled

// ============================================================================
// Static Inline Functions (must be in each compilation unit)
// ============================================================================

static inline void* blorp_simd_alloc(size_t size) {
    #if defined(BLORP_SIMD_AVX) || defined(BLORP_SIMD_AVX2)
        return aligned_alloc(32, ((size + 31) / 32) * 32);
    #elif defined(BLORP_SIMD_SSE2) || defined(BLORP_SIMD_SSE4) || defined(BLORP_SIMD_NEON)
        return aligned_alloc(16, ((size + 15) / 16) * 16);
    #else
        return malloc(size);
    #endif
}

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

void* blorp_alloc(size_t size);
uint32_t blorp_get_destructor_id(_Atomic uint32_t* cache, blorp_destructor_fn fn);
void blorp_set_destructor_id(void* obj, uint32_t id);
#define BLORP_SET_DESTRUCTOR(ptr, fn) do { \
    static _Atomic uint32_t __blorp_destructor_id = 0; \
    blorp_set_destructor_id((void*)(ptr), \
        blorp_get_destructor_id(&__blorp_destructor_id, (blorp_destructor_fn)(fn))); \
} while (0)

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

static inline void blorp_tuple_set_rc(blorp_Tuple* t, long mask) {
    t->release_mask = mask;
    // blorp_tuple_destructor is defined in runtime.c — installed via compact id
    extern void blorp_tuple_destructor(void*);
    BLORP_SET_DESTRUCTOR(t, blorp_tuple_destructor);
}

static inline void* blorp_call1(blorp_Closure* closure, void* arg) {
    typedef void* (*fn1_t)(void*, void*);
    fn1_t f = (fn1_t)closure->func;
    return f(closure->env, arg);
}

static inline void* blorp_call2(blorp_Closure* closure, void* arg1, void* arg2) {
    typedef void* (*fn2_t)(void*, void*, void*);
    fn2_t f = (fn2_t)closure->func;
    return f(closure->env, arg1, arg2);
}

static inline void* blorp_call3(blorp_Closure* closure, void* arg1, void* arg2, void* arg3) {
    typedef void* (*fn3_t)(void*, void*, void*, void*);
    fn3_t f = (fn3_t)closure->func;
    return f(closure->env, arg1, arg2, arg3);
}

static inline void* blorp_call4(blorp_Closure* closure, void* arg1, void* arg2, void* arg3, void* arg4) {
    typedef void* (*fn4_t)(void*, void*, void*, void*, void*);
    fn4_t f = (fn4_t)closure->func;
    return f(closure->env, arg1, arg2, arg3, arg4);
}

// ============================================================================
// Extern globals (defined in runtime.o)
// ============================================================================

extern void* __blorp_none_singleton_ptr;
extern _Thread_local void* __blorp_current_task;

// ============================================================================
// Forward Declarations — All non-static runtime functions
// ============================================================================

// ARC / Memory Management
void* blorp_alloc(size_t size);
void blorp_move_ref(void* obj);
void blorp_set_type_tag(void* obj, const char* tag);
uint32_t blorp_get_destructor_id(_Atomic uint32_t* cache, blorp_destructor_fn fn);
void blorp_set_destructor_id(void* obj, uint32_t id);
#define BLORP_TAG(ptr, tag) blorp_set_type_tag((void*)(ptr), (tag))

// Release slow path (destructor + free + stats) — defined in runtime.o
void blorp_release_slow_extern(void* obj);
void blorp_release_arc_only_slow_extern(void* obj);

// Single-threaded mode: use plain increment/decrement instead of atomics
#ifdef BLORP_SINGLE_THREADED
  #define BLORP_RC_LOAD(p)       (*(long*)(&(p)))
  #define BLORP_RC_INC(p)        (++(*(long*)(&(p))))
  #define BLORP_RC_DEC_PREV(p)   ((*(long*)(&(p)))--)

#else
  #define BLORP_RC_LOAD(p)       atomic_load(&(p))
  #define BLORP_RC_INC(p)        atomic_fetch_add(&(p), 1)
  #define BLORP_RC_DEC_PREV(p)   atomic_fetch_sub(&(p), 1)
#endif

// Inline fast paths for ARC hot functions (avoids cross-TU call overhead)
static inline void* blorp_retain(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return NULL;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return obj;
    BLORP_RC_INC(header->refcount);
    return obj;
}

static inline void blorp_release(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return;
    long prev = BLORP_RC_DEC_PREV(header->refcount);
    if (__builtin_expect(prev == 1, 0)) {
        blorp_release_slow_extern(obj);
    }
}

static inline void blorp_release_arc_only(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return;
    blorp_Object* header = (blorp_Object*)obj;
    if (__builtin_expect(BLORP_RC_LOAD(header->refcount) == BLORP_IMMORTAL_REFCOUNT, 0)) return;
    long prev = BLORP_RC_DEC_PREV(header->refcount);
    if (__builtin_expect(prev == 1, 0)) {
        blorp_release_arc_only_slow_extern(obj);
    }
}

void blorp_cleanup_release_arc_value(void* value);
void blorp_cleanup_release_arc_only_value(void* value);
void __blorp_task_cleanup_push_slow(blorp_CancelCleanupFrame* frame,
                                    const void* slot, void* value,
                                    blorp_CancelCleanupFn release_value);
void __blorp_task_cleanup_pop_slot_slow(const void* slot);

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

static inline void* blorp_stack_result_payload(blorp_StackResult res) {
    if (res.tag == BLORP_TAG_OK) return res.data.Ok.field0;
    if (res.tag == BLORP_TAG_ERR) return res.data.Err.field0;
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

static inline bool blorp_is_unique(void* obj) {
    if (__builtin_expect(obj == NULL, 0)) return false;
    blorp_Object* header = (blorp_Object*)obj;
#ifdef BLORP_SINGLE_THREADED
    return header->refcount == 1;
#else
    return atomic_load_explicit(&header->refcount, memory_order_relaxed) == 1;
#endif
}

// (removed blorp_list_len — now IR intrinsic)

static inline void* blorp_list_get_inline(blorp_List* list, long index) {
    if (__builtin_expect(!list || index < 0 || index >= list->len, 0)) return NULL;
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
#define blorp_list_get blorp_list_get_inline

static inline void blorp_list_set_raw_inline(blorp_List* list, long index, void* value) {
    if (__builtin_expect(!list || index < 0 || index >= list->capacity, 0)) return;
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
#define blorp_list_set_raw blorp_list_set_raw_inline

static inline void blorp_list_set_raw_copy_inline(blorp_List* list, long index, const void* value) {
    if (__builtin_expect(!list || index < 0 || index >= list->capacity, 0)) return;
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
#define blorp_list_set_raw_copy blorp_list_set_raw_copy_inline

// Struct boxing for container storage (tuples)
static inline void* blorp_box_struct(void* data, size_t size) {
    void* boxed = blorp_alloc(sizeof(blorp_Object) + size);
    memcpy((char*)boxed + sizeof(blorp_Object), data, size);
    return boxed;
}

#define blorp_unbox_struct(ptr, type) \
    (*(type*)((char*)(ptr) + sizeof(blorp_Object)))

// Safe Arithmetic
blorp_StackOption_Int blorp_option_div_int(long a, long b);
blorp_StackOption_Int blorp_option_mod_int(long a, long b);
long blorp_checked_div_int(long a, long b);
long blorp_checked_mod_int(long a, long b);

// Unsafe Arithmetic
long blorp_unsafe_div_int(long a, long b);
long blorp_unsafe_mod_int(long a, long b);

// String Operations
blorp_String* blorp_string_literal(const char* cstr);
blorp_String* blorp_string_literal_len(const char* bytes, long len);
blorp_String* blorp_string_create(const char* cstr);
blorp_String* blorp_string_concat(const blorp_String* a, const blorp_String* b);
blorp_String* blorp_string_concat_consume(blorp_String* a, blorp_String* b);
blorp_String* blorp_string_concat_many(long count, ...);
bool blorp_string_eq(const blorp_String* a, const blorp_String* b);
bool blorp_string_eq_cstr(const blorp_String* s, const char* cstr);
bool blorp_string_eq_consume(blorp_String* a, blorp_String* b);
long blorp_string_compare(const blorp_String* a, const blorp_String* b);
long blorp_string_compare_consume(blorp_String* a, blorp_String* b);
// (removed blorp_char_at — now IR intrinsic)
blorp_String* blorp_from_char(int32_t c);
blorp_String* blorp_from_chars(blorp_List* chars);
blorp_String* blorp_string_with_capacity(long cap);
blorp_String* blorp_string_append(blorp_String* s, const blorp_String* other);
blorp_String* blorp_string_copy_ffi(blorp_String* src);
blorp_Vector* blorp_parse_json_float_array(const char* json, const char* field_name);
char* blorp_json_strip_array(const char* json, const char* field_name);

// I/O
void blorp_print(blorp_String* s);
void blorp_puts(blorp_String* s);
void blorp_print_error(blorp_String* s);
blorp_String* blorp_read_all(void);
blorp_String* blorp_read_line(void);
blorp_String* blorp_read_line_or_empty(void);
blorp_String* blorp_input(blorp_String* prompt);
blorp_String* blorp_input_or_empty(blorp_String* prompt);
// (removed blorp_exit — now IR intrinsic)

// Conversion
blorp_String* blorp_to_string(long i);
blorp_String* blorp_int128_to_string(__int128 v);
blorp_String* blorp_uint128_to_string(unsigned __int128 v);
blorp_String* blorp_float_to_string(double f);
blorp_String* blorp_format_float(double f, long decimals);
blorp_String* blorp_float32_to_string(float f);
#ifdef __FLT16_MAX__
blorp_String* blorp_float16_to_string(_Float16 f);
#endif
blorp_String* blorp_bool_to_string(bool b);
blorp_String* blorp_bool_to_string_long(long b);
long blorp_to_int(blorp_String* s);
double blorp_to_float(blorp_String* s);
int8_t blorp_to_int8(long x);
int16_t blorp_to_int16(long x);
int32_t blorp_to_int32(long x);
__int128 blorp_to_int128(long x);
uint8_t blorp_to_uint8(long x);
uint16_t blorp_to_uint16(long x);
uint32_t blorp_to_uint32(long x);
uint64_t blorp_to_uint64(long x);
unsigned __int128 blorp_to_uint128(long x);

// N-D tensor constructors
blorp_Vector* blorp_tensor3_new(void* value, long d1, long d2, long d3);
blorp_Vector* blorp_tensor4_new(void* value, long d1, long d2, long d3, long d4);
blorp_Vector* blorp_tensor5_new(void* value, long d1, long d2, long d3, long d4, long d5);

// List Core
blorp_List* blorp_list_new(long initial_capacity);
blorp_List* blorp_list_new_inline(long initial_capacity, int16_t elem_size);
// blorp_list_get — provided as static inline above

// Option / Result / ConcurrencyError
blorp_Option* blorp_option_some(void* value);
blorp_Option* blorp_option_none(void);
blorp_Vector* blorp_assert_shape(blorp_Vector* tensor, long expected_len);
blorp_Vector* blorp_assert_shape_nullable(blorp_Vector* tensor, long expected_len);
blorp_Result* blorp_result_ok(void* value);
blorp_Result* blorp_result_err(void* value);
blorp_ConcurrencyError* blorp_TaskFailed(void* msg);

// Safe Access / Parsing
// (removed blorp_list_get_opt — now IR intrinsic)
blorp_StackOption_Char blorp_string_get_opt(const blorp_String* s, long index);
blorp_StackOption_Int blorp_parse_int(blorp_String* s);
blorp_StackOption_Float blorp_parse_float(blorp_String* s);

// List Mutation
blorp_List* blorp_list_append(blorp_List* list, void* element);
blorp_List* blorp_list_append_owned(blorp_List* list, void* element);
// (removed blorp_list_set_releasing — now IR intrinsic)
// (removed blorp_list_set_inplace — now IR intrinsic)
// (removed blorp_list_set_releasing_inplace — now IR intrinsic)
// (removed blorp_list_insert_inplace — now IR intrinsic)
// (removed blorp_list_remove_inplace — now IR intrinsic)
blorp_List* blorp_list_build(long count, ...);
blorp_List* blorp_list_copy_ffi(blorp_List* src);
blorp_List* blorp_list_cow(blorp_List* list);
blorp_List* blorp_list_ensure_capacity(blorp_List* list, long min_cap);
blorp_List* blorp_list_reuse_alloc(blorp_List* list, long min_cap);
void blorp_list_copy_span_uninit(blorp_List* dst, long dst_start, blorp_List* src, long src_start, long count);
blorp_List* blorp_list_reverse_owned(blorp_List* list);
void blorp_list_release_elem(blorp_List* list, long index);
void blorp_list_retain_for(blorp_List* list, void* value);
blorp_List* blorp_list_handoff_begin_borrow(long min_cap, void (*elem_release)(void*), uint8_t storage_mode, int16_t elem_size);
blorp_List* blorp_list_handoff_begin_reuse(blorp_List* source, long min_cap, void (*elem_release)(void*), uint8_t storage_mode, int16_t elem_size, bool* reused_out);
void blorp_list_handoff_set_owned(blorp_List* list, long index, void* value);
void blorp_list_handoff_set_source_slot(blorp_List* result, long out_index, blorp_List* source, long source_index);
void blorp_list_handoff_finish(blorp_List* result, long out_len, long old_len, bool reused, blorp_List* consumed_source);
blorp_String* blorp_string_alloc(long capacity);
long blorp_string_find_byte_from(const blorp_String* s, long byte, long start);
blorp_Bytes* blorp_bytes_alloc(long capacity);
blorp_Bytes* blorp_bytes_cow(blorp_Bytes* b);
blorp_Bytes* blorp_bytes_copy_ffi(blorp_Bytes* src);
blorp_String* blorp_string_cow(blorp_String* s);
blorp_String* blorp_string_ensure_capacity(blorp_String* s, long min_cap);

// Packed Enum Tensor Helpers (sub-byte element storage)
static inline long blorp_packed_byte_count(long n, int8_t es) {
    if (es > 0) return n * (long)es;
    return (n * (long)(-es) + 7) / 8;
}
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

static inline float blorp_vector_read_f32(const blorp_Vector* v, long index) {
    if (!v || index < 0 || index >= v->capacity) return 0.0f;
    if (v->storage_mode == BLORP_VECTOR_STORAGE_F32
        && v->elem_size == (int16_t)sizeof(float)) {
        return ((float*)v->data)[index];
    }
    return blorp_unbox_float32(v->data[index]);
}

static inline int blorp_vector_is_f64_packed(const blorp_Vector* v) {
    return v && v->storage_mode == BLORP_VECTOR_STORAGE_F64 && v->elem_size == (int16_t)sizeof(double);
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

#ifdef __FLT16_MAX__
static inline _Float16 blorp_vector_read_f16(const blorp_Vector* v, long index) {
    return blorp_unbox_float16(v->data[index]);
}
#endif

// Vector / Tensor Core
blorp_Vector* blorp_vector_new_fill(void* value, long size);
blorp_Vector* blorp_matrix_new_fill(void* value, long rows, long cols);
blorp_Vector* blorp_vector_new_fill_f64(double value, long size);
blorp_Vector* blorp_matrix_new_fill_f64(double value, long rows, long cols);
blorp_Vector* blorp_vector_new_fill_f32(float value, long size);
blorp_Vector* blorp_matrix_new_fill_f32(float value, long rows, long cols);
blorp_Vector* blorp_vector_new_fill_i64(long value, long size);
blorp_Vector* blorp_matrix_new_fill_i64(long value, long rows, long cols);
blorp_Vector* blorp_vector_new_fill_sized(void* value, long size, long elem_byte_size);
blorp_Vector* blorp_matrix_new_fill_sized(void* value, long rows, long cols, long elem_byte_size);
blorp_Vector* blorp_tensor3_new_sized(void* value, long d1, long d2, long d3, long elem_byte_size);
blorp_Vector* blorp_tensor4_new_sized(void* value, long d1, long d2, long d3, long d4, long elem_byte_size);
blorp_Vector* blorp_tensor5_new_sized(void* value, long d1, long d2, long d3, long d4, long d5, long elem_byte_size);
blorp_Vector* blorp_vector_new(long size);
blorp_Vector* blorp_vector_new_noinit(long size);
blorp_Vector* blorp_tensor_new(long first_dim, long total_capacity);
blorp_Vector* blorp_tensor_peel_row(blorp_Vector* tensor, long row_idx, long sub_len);
blorp_Vector* blorp_vector_abs(blorp_Vector* v);
blorp_Vector* blorp_vector_new_f64(long size);
blorp_Vector* blorp_vector_new_f32(long size);
blorp_Vector* blorp_vector_new_i64(long size);
blorp_Vector* blorp_vector_new_sized(long size, long elem_byte_size);
blorp_Vector* blorp_tensor_new_sized(long first_dim, long total_capacity, long elem_byte_size);
void* blorp_vector_get_or(blorp_Vector* arr, long index, void* default_val);
blorp_Vector* blorp_tensor_new_f64(long first_dim, long total_capacity);
blorp_Vector* blorp_tensor_new_f32(long first_dim, long total_capacity);
blorp_Vector* blorp_tensor_new_i64(long first_dim, long total_capacity);
blorp_Vector* blorp_vector_new_packed(long size, int8_t elem_size);
blorp_Vector* blorp_tensor_new_packed(long first_dim, long total, int8_t elem_size);
blorp_Vector* blorp_vector_new_fill_packed(long value, long size, int8_t elem_size);
blorp_Vector* blorp_matrix_new_fill_packed(long value, long rows, long cols, int8_t elem_size);
blorp_Vector* blorp_vector_set_inplace_packed(blorp_Vector* arr, long index, long value);
blorp_String* blorp_vector_to_string_packed_enum(blorp_Vector* v, blorp_String* (*to_str)(long));
blorp_String* blorp_vector_to_string_bool(blorp_Vector* v);
// (removed blorp_vector_len — now IR intrinsic)
void* blorp_vector_get(blorp_Vector* arr, long index);
void blorp_vector_set(blorp_Vector* arr, long index, void* value);
void* blorp_checked_get(blorp_Vector* arr, long index);
double blorp_checked_get_f64(blorp_Vector* arr, long index);
float blorp_checked_get_f32(blorp_Vector* arr, long index);
blorp_Vector* blorp_checked_set(blorp_Vector* arr, long index, void* value);
blorp_Vector* blorp_checked_slice(blorp_Vector* arr, long start, long end_idx);
void* blorp_matrix_checked_get(blorp_Vector* arr, long row, long col);
double blorp_matrix_checked_get_f64(blorp_Vector* arr, long row, long col);
float blorp_matrix_checked_get_f32(blorp_Vector* arr, long row, long col);
blorp_Vector* blorp_matrix_checked_set(blorp_Vector* arr, long row, long col, void* value);
blorp_Vector* blorp_matrix_checked_set_f64(blorp_Vector* arr, long row, long col, double value);
blorp_Vector* blorp_matrix_checked_set_f32(blorp_Vector* arr, long row, long col, float value);
blorp_Vector* blorp_matrix_checked_set_i64(blorp_Vector* arr, long row, long col, long value);
blorp_Vector* blorp_vector_set_inplace(blorp_Vector* arr, long index, void* value);
blorp_Vector* blorp_vector_set_inplace_f32(blorp_Vector* arr, long index, float value);
blorp_Vector* blorp_vector_set_inplace_f64(blorp_Vector* arr, long index, double value);
blorp_Vector* blorp_vector_set_inplace_i64(blorp_Vector* arr, long index, long value);
blorp_Vector* blorp_vector_set_inplace_f16(blorp_Vector* arr, long index, _Float16 value);
blorp_Option* blorp_vector_set_cow(blorp_Vector* arr, long index, void* value);
blorp_Vector* blorp_vector_set_cow_nullable(blorp_Vector* arr, long index, void* value);
blorp_Option* blorp_vector_set_cow_f32(blorp_Vector* arr, long index, float value);
blorp_Vector* blorp_vector_set_cow_nullable_f32(blorp_Vector* arr, long index, float value);
blorp_Option* blorp_vector_set_cow_i64(blorp_Vector* arr, long index, long value);
blorp_Vector* blorp_vector_set_cow_nullable_i64(blorp_Vector* arr, long index, long value);
blorp_Option* blorp_vector_get_opt(blorp_Vector* arr, long index);
void* blorp_vector_get_nullable(blorp_Vector* arr, long index);
blorp_StackOption_Int blorp_vector_get_opt_int(blorp_Vector* arr, long index);
blorp_StackOption_Int8 blorp_vector_get_opt_int8(blorp_Vector* arr, long index);
blorp_StackOption_Int16 blorp_vector_get_opt_int16(blorp_Vector* arr, long index);
blorp_StackOption_Int32 blorp_vector_get_opt_int32(blorp_Vector* arr, long index);
blorp_StackOption_Int64 blorp_vector_get_opt_int64(blorp_Vector* arr, long index);
blorp_StackOption_UInt8 blorp_vector_get_opt_uint8(blorp_Vector* arr, long index);
blorp_StackOption_UInt16 blorp_vector_get_opt_uint16(blorp_Vector* arr, long index);
blorp_StackOption_UInt32 blorp_vector_get_opt_uint32(blorp_Vector* arr, long index);
blorp_StackOption_UInt64 blorp_vector_get_opt_uint64(blorp_Vector* arr, long index);
blorp_StackOption_Float blorp_vector_get_opt_float(blorp_Vector* arr, long index);
blorp_StackOption_Bool blorp_vector_get_opt_bool(blorp_Vector* arr, long index);
blorp_StackOption_Char blorp_vector_get_opt_char(blorp_Vector* arr, long index);
blorp_StackOption_Float32 blorp_vector_get_opt_f32(blorp_Vector* arr, long index);
#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_vector_get_opt_f16(blorp_Vector* arr, long index);
#endif
blorp_Option* blorp_matrix_get_opt(blorp_Vector* arr, long row, long col);
void* blorp_matrix_get_nullable(blorp_Vector* arr, long row, long col);
blorp_StackOption_Int blorp_matrix_get_opt_int(blorp_Vector* arr, long row, long col);
blorp_StackOption_Int8 blorp_matrix_get_opt_int8(blorp_Vector* arr, long row, long col);
blorp_StackOption_Int16 blorp_matrix_get_opt_int16(blorp_Vector* arr, long row, long col);
blorp_StackOption_Int32 blorp_matrix_get_opt_int32(blorp_Vector* arr, long row, long col);
blorp_StackOption_Int64 blorp_matrix_get_opt_int64(blorp_Vector* arr, long row, long col);
blorp_StackOption_UInt8 blorp_matrix_get_opt_uint8(blorp_Vector* arr, long row, long col);
blorp_StackOption_UInt16 blorp_matrix_get_opt_uint16(blorp_Vector* arr, long row, long col);
blorp_StackOption_UInt32 blorp_matrix_get_opt_uint32(blorp_Vector* arr, long row, long col);
blorp_StackOption_UInt64 blorp_matrix_get_opt_uint64(blorp_Vector* arr, long row, long col);
blorp_StackOption_Float blorp_matrix_get_opt_float(blorp_Vector* arr, long row, long col);
blorp_StackOption_Bool blorp_matrix_get_opt_bool(blorp_Vector* arr, long row, long col);
blorp_StackOption_Char blorp_matrix_get_opt_char(blorp_Vector* arr, long row, long col);
blorp_StackOption_Float32 blorp_matrix_get_opt_f32(blorp_Vector* arr, long row, long col);
#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_matrix_get_opt_f16(blorp_Vector* arr, long row, long col);
#endif
blorp_Option* blorp_matrix_set_opt(blorp_Vector* arr, long row, long col, void* val);
blorp_Vector* blorp_matrix_set_opt_nullable(blorp_Vector* arr, long row, long col, void* val);
blorp_Option* blorp_matrix_set_opt_i64(blorp_Vector* arr, long row, long col, long val);
blorp_Vector* blorp_matrix_set_opt_nullable_i64(blorp_Vector* arr, long row, long col, long val);
blorp_Vector* blorp_vector_copy_ffi(blorp_Vector* src);
blorp_Vector* blorp_vector_cow_unique(blorp_Vector* arr);

// Vector Element-wise Ops
blorp_Vector* blorp_vector_op(int op, int elem_type, const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_op_cow(int op, int elem_type, blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_add_i64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_sub_i64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_mul_i64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_div_i64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_vector_mod_i64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_add_f32(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_sub_f32(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_mul_f32(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_div_f32(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_add_f64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_sub_f64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_mul_f64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_div_f64(const blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_tensor_add_scaled_f64_cow(blorp_Vector* target, const blorp_Vector* input, double scale);
blorp_Vector* blorp_tensor_add_scaled_f32_cow(blorp_Vector* target, const blorp_Vector* input, float scale);

// Vector Reductions

// Vector Stats
long blorp_vector_max_int(blorp_Vector* v);
long blorp_vector_min_int(blorp_Vector* v);
double blorp_vector_max_float(blorp_Vector* v);
double blorp_vector_min_float(blorp_Vector* v);
float blorp_vector_max_float32(blorp_Vector* v);
float blorp_vector_min_float32(blorp_Vector* v);
#ifdef __FLT16_MAX__
_Float16 blorp_vector_max_float16(blorp_Vector* v);
_Float16 blorp_vector_min_float16(blorp_Vector* v);
#endif
double blorp_vector_norm(blorp_Vector* v);

// Vector Scalar Ops
blorp_Vector* blorp_vector_add_int(blorp_Vector* a, blorp_Vector* b);
blorp_Vector* blorp_vector_add_float(blorp_Vector* a, blorp_Vector* b);
blorp_Vector* blorp_vector_scalar_add_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_sub_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_mul_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_div_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_mod_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_rev_sub_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_rev_div_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_rev_mod_i64(const blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_add_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_sub_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_mul_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_div_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_rev_sub_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_rev_div_f64(const blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_add_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_sub_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_mul_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_div_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_rev_sub_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_rev_div_f32(const blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_op_int(int op, blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_op_float(int op, blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_op_int_cow(int op, blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_op_float_cow(int op, blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_op_rev_int(int op, blorp_Vector* v, long scalar);
blorp_Vector* blorp_vector_scalar_op_rev_float(int op, blorp_Vector* v, double scalar);
blorp_Vector* blorp_vector_scalar_op_float32(int op, blorp_Vector* v, float scalar);
blorp_Vector* blorp_vector_scalar_op_rev_float32(int op, blorp_Vector* v, float scalar);
#ifdef __FLT16_MAX__
blorp_Vector* blorp_vector_scalar_op_float16(int op, blorp_Vector* v, _Float16 scalar);
blorp_Vector* blorp_vector_scalar_op_rev_float16(int op, blorp_Vector* v, _Float16 scalar);
#endif
blorp_Vector* blorp_vector_slice(blorp_Vector* v, long start, long end);
long blorp_vector_eq(int elem_type, blorp_Vector* a, blorp_Vector* b);

// Vector Transcendental
blorp_Vector* blorp_vector_exp(blorp_Vector* v);
blorp_Vector* blorp_vector_log(blorp_Vector* v);
blorp_Vector* blorp_vector_sqrt(blorp_Vector* v);

// Vector Float32 Ops
float blorp_vector_norm_float32(blorp_Vector* v);
blorp_Vector* blorp_vector_exp_float32(blorp_Vector* v);
blorp_Vector* blorp_vector_log_float32(blorp_Vector* v);
blorp_Vector* blorp_vector_sqrt_float32(blorp_Vector* v);
blorp_String* blorp_vector_to_string_float32(blorp_Vector* v);

// Vector Float16 Ops
#ifdef __FLT16_MAX__
_Float16 blorp_vector_norm_float16(blorp_Vector* v);
blorp_Vector* blorp_vector_exp_float16(blorp_Vector* v);
blorp_Vector* blorp_vector_log_float16(blorp_Vector* v);
blorp_Vector* blorp_vector_sqrt_float16(blorp_Vector* v);
blorp_String* blorp_vector_to_string_float16(blorp_Vector* v);
#endif // __FLT16_MAX__

// Vector/List to_string
blorp_String* blorp_vector_to_string_int(blorp_Vector* v);
blorp_String* blorp_vector_to_string_float(blorp_Vector* v);
blorp_String* blorp_list_to_string_int(blorp_List* list);
blorp_String* blorp_list_to_string_float(blorp_List* list);
blorp_String* blorp_list_to_string_float32(blorp_List* list);
#ifdef __FLT16_MAX__
blorp_String* blorp_list_to_string_float16(blorp_List* list);
#endif
blorp_String* blorp_list_to_string_string(blorp_List* list);
blorp_String* blorp_list_to_string_bool(blorp_List* list);
blorp_String* blorp_list_to_string_cb(blorp_List* list, blorp_String* (*elem_to_str)(void*));

// Vector Construction / Argmax / Cumsum / Cross / Tensor
// (removed blorp_arange — now IR intrinsic)
// (removed blorp_linspace — now IR intrinsic)
blorp_Vector* blorp_vector_cross_float(blorp_Vector* a, blorp_Vector* b);
blorp_Vector* blorp_tensor_slice_row(blorp_Vector* tensor, long row_index, long row_size, long result_first_dim);
blorp_Vector* blorp_tensor_matrix_multiply_int(blorp_Vector* a, blorp_Vector* b, long m, long k, long n);
blorp_Vector* blorp_tensor_matrix_multiply_float(blorp_Vector* a, blorp_Vector* b, long m, long k, long n);
blorp_Vector* blorp_tensor_matrix_multiply_float32(blorp_Vector* a, blorp_Vector* b, long m, long k, long n);
#ifdef __FLT16_MAX__
blorp_Vector* blorp_tensor_matrix_multiply_float16(blorp_Vector* a, blorp_Vector* b, long m, long k, long n);
#endif
blorp_Vector* blorp_tensor_transpose(blorp_Vector* mat, long rows, long cols);
blorp_Vector* blorp_tensor_matrix_vector_multiply_int(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_matrix_vector_multiply_float(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_transposed_matrix_vector_multiply_float(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_transposed_matrix_vector_multiply_int(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_transposed_matrix_vector_multiply_float32(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_matrix_vector_multiply_float32(blorp_Vector* w, blorp_Vector* x, long m, long n);
#ifdef __FLT16_MAX__
blorp_Vector* blorp_tensor_matrix_vector_multiply_float16(blorp_Vector* w, blorp_Vector* x, long m, long n);
blorp_Vector* blorp_tensor_transposed_matrix_vector_multiply_float16(blorp_Vector* w, blorp_Vector* x, long m, long n);
#endif
blorp_Vector* blorp_tensor_outer_int(blorp_Vector* a, blorp_Vector* b, long m, long n);
blorp_Vector* blorp_tensor_outer_float(blorp_Vector* a, blorp_Vector* b, long m, long n);
blorp_Vector* blorp_tensor_outer_float32(blorp_Vector* a, blorp_Vector* b, long m, long n);
#ifdef __FLT16_MAX__
blorp_Vector* blorp_tensor_outer_float16(blorp_Vector* a, blorp_Vector* b, long m, long n);
#endif
long blorp_length(void* collection);

// Bytes
blorp_Bytes* blorp_bytes_new(long capacity);
blorp_Bytes* blorp_bytes_from_string(blorp_String* s);
blorp_String* blorp_bytes_to_string(blorp_Bytes* b);
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
blorp_Bytes* blorp_bytes_from_hex(const blorp_String* s);
blorp_Bytes* blorp_bytes_from_hex_nullable(const blorp_String* s);

// Encoding / Decoding
blorp_Bytes* blorp_encode_utf8(blorp_List* chars);
blorp_List* blorp_decode_utf8(blorp_Bytes* b);
blorp_List* blorp_decode_utf8_nullable(blorp_Bytes* b);
blorp_String* blorp_base64_encode(const blorp_String* s);
blorp_String* blorp_base64_decode(const blorp_String* s);
blorp_String* blorp_base64_decode_nullable(const blorp_String* s);

// TCP Networking
blorp_Result* blorp_tcp_listen(blorp_String* host, long port, long backlog);
blorp_Result* blorp_tcp_accept(blorp_TcpListener* listener);
blorp_Result* blorp_tcp_connect(blorp_String* host, long port);
blorp_Result* blorp_tcp_read(blorp_TcpStream* stream, long max_bytes);
blorp_Result* blorp_tcp_write(blorp_TcpStream* stream, blorp_Bytes* data);
void blorp_tcp_close_listener(blorp_TcpListener* listener);
void blorp_tcp_close_stream(blorp_TcpStream* stream);
blorp_Result* blorp_tcp_set_reuse_addr(blorp_TcpListener* listener);
blorp_Result* blorp_tcp_local_port_listener(blorp_TcpListener* listener);
blorp_Result* blorp_tcp_local_port_stream(blorp_TcpStream* stream);
blorp_Result* blorp_tcp_set_timeout_listener(blorp_TcpListener* listener, long ms);
blorp_Result* blorp_tcp_set_timeout_stream(blorp_TcpStream* stream, long ms);
blorp_TcpListener* blorp_tcp_listener_from_fd(long fd);
blorp_TcpStream* blorp_tcp_stream_from_fd(long fd);
long blorp_tcp_listener_fd(blorp_TcpListener* listener);
long blorp_tcp_stream_fd(blorp_TcpStream* stream);
int blorp_io_reactor_start(void);
void blorp_io_reactor_shutdown(void);
int blorp_io_reactor_smoke_test(void);

// Dict
blorp_Dict* blorp_dict_new(void);
blorp_Dict* blorp_dict_new_string(void);
blorp_Dict* blorp_dict_new_float(void);
blorp_Dict* blorp_dict_new_custom(
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*key_release)(void*)
);
blorp_Dict* blorp_dict_with_capacity(long expected_len);
blorp_Dict* blorp_dict_with_capacity_string(long expected_len);
blorp_Dict* blorp_dict_with_capacity_float(long expected_len);
blorp_Dict* blorp_dict_with_capacity_custom(
    long expected_len,
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*key_release)(void*)
);
void blorp_dict_init_key_string(blorp_Dict* dict);
void blorp_dict_init_key_float(blorp_Dict* dict);
bool blorp_dict_get_raw(blorp_Dict* dict, void* key, void** out_value);
blorp_Option* blorp_dict_get(blorp_Dict* dict, void* key);
void* blorp_dict_get_nullable(blorp_Dict* dict, void* key);
blorp_StackOption_Int blorp_dict_get_int(blorp_Dict* dict, void* key);
blorp_StackOption_Int8 blorp_dict_get_int8(blorp_Dict* dict, void* key);
blorp_StackOption_Int16 blorp_dict_get_int16(blorp_Dict* dict, void* key);
blorp_StackOption_Int32 blorp_dict_get_int32(blorp_Dict* dict, void* key);
blorp_StackOption_Int64 blorp_dict_get_int64(blorp_Dict* dict, void* key);
blorp_StackOption_UInt8 blorp_dict_get_uint8(blorp_Dict* dict, void* key);
blorp_StackOption_UInt16 blorp_dict_get_uint16(blorp_Dict* dict, void* key);
blorp_StackOption_UInt32 blorp_dict_get_uint32(blorp_Dict* dict, void* key);
blorp_StackOption_UInt64 blorp_dict_get_uint64(blorp_Dict* dict, void* key);
blorp_StackOption_Float blorp_dict_get_float(blorp_Dict* dict, void* key);
blorp_StackOption_Bool blorp_dict_get_bool(blorp_Dict* dict, void* key);
blorp_StackOption_Char blorp_dict_get_char(blorp_Dict* dict, void* key);
blorp_StackOption_Float32 blorp_dict_get_f32(blorp_Dict* dict, void* key);
#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_dict_get_f16(blorp_Dict* dict, void* key);
#endif
blorp_Dict* blorp_dict_insert(blorp_Dict* dict, void* key, void* value);
blorp_Dict* blorp_dict_remove(blorp_Dict* dict, void* key);
blorp_List* blorp_dict_entries(blorp_Dict* dict);

// Set
blorp_Set* blorp_set_new(void);
blorp_Set* blorp_set_new_string(void);
blorp_Set* blorp_set_new_float(void);
blorp_Set* blorp_set_new_custom(
    unsigned long (*hash_fn)(void*),
    bool (*eq_fn)(void*, void*),
    void (*elem_release)(void*)
);
blorp_Set* blorp_set_add(blorp_Set* set, void* key);
blorp_Set* blorp_set_remove(blorp_Set* set, void* key);

// sort/sort_by moved to blorp source (std/list.brp merge sort)

// Hash table intrinsic helpers (for IR-composed set/dict operations)
blorp_Set* blorp_set_alloc(long capacity);
blorp_SetEntry* blorp_set_alloc_entry(void* key);
void blorp_set_free_entry(blorp_Set* set, blorp_SetEntry* entry);
blorp_Set* blorp_set_cow(blorp_Set* set);
blorp_Set* blorp_set_reuse_alloc(blorp_Set* set, long min_cap);
void blorp_set_resize_to(blorp_Set* set, long new_cap);
void blorp_set_reserve_for_len(blorp_Set* set, long len);
blorp_Dict* blorp_dict_alloc(long capacity);
blorp_Dict* blorp_dict_cow(blorp_Dict* dict);
blorp_Dict* blorp_dict_reuse_alloc(blorp_Dict* dict, long min_cap);
void blorp_dict_resize_to(blorp_Dict* dict, long new_cap);

// Thread Pool / Concurrency
void blorp_thread_pool_init(long max_threads);
void blorp_thread_pool_shutdown(void);
void* blorp_task_spawn(blorp_Closure* func);
void* blorp_task_spawn_owned(blorp_Closure* func);
void* blorp_task_spawn_rc(blorp_Closure* func);
void* blorp_task_spawn_owned_rc(blorp_Closure* func);
void blorp_task_batch_init(blorp_TaskBatch* batch);
void blorp_task_batch_flush(blorp_TaskBatch* batch);
void* blorp_task_spawn_owned_in_batch(
    blorp_TaskBatch* batch,
    blorp_Closure* func
);
void* blorp_task_spawn_owned_rc_in_batch(
    blorp_TaskBatch* batch,
    blorp_Closure* func
);
void blorp_task_init_result_rc(void* t);
void blorp_detach(void* fn);
void blorp_detach_rc(void* fn);
void* blorp_task_join(void* t);
void* blorp_task_try_join(void* t);
void* blorp_concurrent_join(void* t, long timeout_ms);
long blorp_concurrent_deadline_us(long timeout_ms);
long blorp_concurrent_remaining_ms(long deadline_us);
long blorp_concurrent_normalize_limit(long requested);
void blorp_task_cancel(void* t);
void blorp_task_cancel_join_release(void* t);
void blorp_sleep(long ms);
void blorp_yield_now(void);
long blorp_max_threads(void);

// Channels
#define BLORP_CHANNEL_SEND_ACCEPTED 0L
#define BLORP_CHANNEL_SEND_WOULD_BLOCK 1L
#define BLORP_CHANNEL_SEND_SEALED 2L
#define BLORP_CHANNEL_SEND_TIMED_OUT 3L

#define BLORP_CHANNEL_RECV_VALUE 0L
#define BLORP_CHANNEL_RECV_WOULD_BLOCK 1L
#define BLORP_CHANNEL_RECV_SEALED 2L
#define BLORP_CHANNEL_RECV_TIMED_OUT 3L

#define BLORP_SELECT_RECV 0L
#define BLORP_SELECT_SEALED 1L
#define BLORP_SELECT_AFTER 2L
#define BLORP_SELECT_CANCELLED 3L

typedef struct {
    long kind;
    blorp_Channel* channel;
    long timeout_ms;
} blorp_SelectArm;

typedef struct {
    long arm_index;
    long kind;
    void* value;
} blorp_SelectResult;

void* blorp_channel_new(long capacity);
long blorp_channel_send(void* c, void* value);
void* blorp_channel_recv(void* c);
long blorp_channel_try_send(void* c, void* value);
long blorp_channel_try_send_status(void* c, void* value);
void* blorp_channel_try_recv(void* c);
void* blorp_channel_recv_timeout(void* c, long timeout_ms);
long blorp_channel_send_timeout(void* c, void* value, long timeout_ms);
long blorp_channel_send_timeout_status(void* c, void* value, long timeout_ms);
void blorp_channel_seal(void* c);
bool blorp_channel_recv_raw(blorp_Channel* ch, void** out);
long blorp_channel_try_recv_status_raw(blorp_Channel* ch, void** out);
bool blorp_channel_try_recv_raw(blorp_Channel* ch, void** out);
long blorp_channel_recv_timeout_status_raw(blorp_Channel* ch, long timeout_ms, void** out);
bool blorp_channel_recv_timeout_raw(blorp_Channel* ch, long timeout_ms, void** out);
blorp_SelectResult blorp_select_wait(blorp_SelectArm* arms, long arm_count);
blorp_StackOption_Int blorp_channel_recv_int(void* c);
blorp_StackOption_Int blorp_channel_try_recv_int(void* c);
blorp_StackOption_Int blorp_channel_recv_timeout_int(void* c, long timeout_ms);
blorp_StackOption_Int8 blorp_channel_recv_int8(void* c);
blorp_StackOption_Int8 blorp_channel_try_recv_int8(void* c);
blorp_StackOption_Int8 blorp_channel_recv_timeout_int8(void* c, long timeout_ms);
blorp_StackOption_Int16 blorp_channel_recv_int16(void* c);
blorp_StackOption_Int16 blorp_channel_try_recv_int16(void* c);
blorp_StackOption_Int16 blorp_channel_recv_timeout_int16(void* c, long timeout_ms);
blorp_StackOption_Int32 blorp_channel_recv_int32(void* c);
blorp_StackOption_Int32 blorp_channel_try_recv_int32(void* c);
blorp_StackOption_Int32 blorp_channel_recv_timeout_int32(void* c, long timeout_ms);
blorp_StackOption_Int64 blorp_channel_recv_int64(void* c);
blorp_StackOption_Int64 blorp_channel_try_recv_int64(void* c);
blorp_StackOption_Int64 blorp_channel_recv_timeout_int64(void* c, long timeout_ms);
blorp_StackOption_UInt8 blorp_channel_recv_uint8(void* c);
blorp_StackOption_UInt8 blorp_channel_try_recv_uint8(void* c);
blorp_StackOption_UInt8 blorp_channel_recv_timeout_uint8(void* c, long timeout_ms);
blorp_StackOption_UInt16 blorp_channel_recv_uint16(void* c);
blorp_StackOption_UInt16 blorp_channel_try_recv_uint16(void* c);
blorp_StackOption_UInt16 blorp_channel_recv_timeout_uint16(void* c, long timeout_ms);
blorp_StackOption_UInt32 blorp_channel_recv_uint32(void* c);
blorp_StackOption_UInt32 blorp_channel_try_recv_uint32(void* c);
blorp_StackOption_UInt32 blorp_channel_recv_timeout_uint32(void* c, long timeout_ms);
blorp_StackOption_UInt64 blorp_channel_recv_uint64(void* c);
blorp_StackOption_UInt64 blorp_channel_try_recv_uint64(void* c);
blorp_StackOption_UInt64 blorp_channel_recv_timeout_uint64(void* c, long timeout_ms);
blorp_StackOption_Float blorp_channel_recv_float(void* c);
blorp_StackOption_Float blorp_channel_try_recv_float(void* c);
blorp_StackOption_Float blorp_channel_recv_timeout_float(void* c, long timeout_ms);
blorp_StackOption_Bool blorp_channel_recv_bool(void* c);
blorp_StackOption_Bool blorp_channel_try_recv_bool(void* c);
blorp_StackOption_Bool blorp_channel_recv_timeout_bool(void* c, long timeout_ms);
blorp_StackOption_Char blorp_channel_recv_char(void* c);
blorp_StackOption_Char blorp_channel_try_recv_char(void* c);
blorp_StackOption_Char blorp_channel_recv_timeout_char(void* c, long timeout_ms);
blorp_StackOption_Float32 blorp_channel_recv_f32(void* c);
blorp_StackOption_Float32 blorp_channel_try_recv_f32(void* c);
blorp_StackOption_Float32 blorp_channel_recv_timeout_f32(void* c, long timeout_ms);
#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_channel_recv_f16(void* c);
blorp_StackOption_Float16 blorp_channel_try_recv_f16(void* c);
blorp_StackOption_Float16 blorp_channel_recv_timeout_f16(void* c, long timeout_ms);
#endif
void* blorp_channel_recv_nullable(void* c);
void* blorp_channel_try_recv_nullable(void* c);
void* blorp_channel_recv_timeout_nullable(void* c, long timeout_ms);

// Stream[T]
typedef enum blorp_StreamElementLayout {
    BLORP_STREAM_ELEM_IMMEDIATE = 0,
    BLORP_STREAM_ELEM_BORROWED_ARC = 1,
    BLORP_STREAM_ELEM_OWNED_ARC = 2,
} blorp_StreamElementLayout;

typedef struct blorp_Stream {
    blorp_Object header;
    bool (*pull)(struct blorp_Stream* self, void** out);
    void* state;
    void (*state_cleanup)(struct blorp_Stream* self);
    blorp_StreamElementLayout elem_layout;
} blorp_Stream;

typedef enum blorp_FallibleStreamPullStatus {
    BLORP_FALLIBLE_STREAM_END = 0,
    BLORP_FALLIBLE_STREAM_ITEM = 1,
    BLORP_FALLIBLE_STREAM_ERROR = 2,
} blorp_FallibleStreamPullStatus;

typedef struct blorp_FallibleStream {
    blorp_Object header;
    blorp_FallibleStreamPullStatus (*pull)(
        struct blorp_FallibleStream* self,
        void** out,
        blorp_FileErrorKind* error_kind,
        blorp_String** error_detail
    );
    void* state;
    void (*state_cleanup)(struct blorp_FallibleStream* self);
    blorp_StreamElementLayout elem_layout;
} blorp_FallibleStream;

blorp_Stream* blorp_stream_from_list(blorp_List* list);
blorp_Stream* blorp_stream_from_range(long start, long end);
blorp_Stream* blorp_stream_repeat(void* value, long elem_layout_code);
blorp_Stream* blorp_stream_unfold(
    void* seed,
    blorp_Closure* func,
    long elem_layout_code,
    long state_layout_code
);
blorp_Stream* blorp_stream_empty(void);
blorp_Stream* blorp_stream_from_lines(blorp_String* path);
blorp_FallibleStream* blorp_file_chunks_reader_raw(const blorp_FileReader* reader);
blorp_FallibleStream* blorp_file_chunks_with_size_reader_raw(const blorp_FileReader* reader, long chunk_size);
blorp_FallibleStream* blorp_file_lines_reader_raw(const blorp_FileReader* reader);
blorp_FallibleStream* blorp_file_bytes_reader_raw(const blorp_FileReader* reader);
blorp_FallibleStream* blorp_file_windows_reader_raw(const blorp_FileReader* reader, long size);
blorp_Stream* blorp_stream_map(blorp_Stream* inner, blorp_Closure* func, long result_elem_layout_code);
blorp_Stream* blorp_stream_filter(blorp_Stream* inner, blorp_Closure* pred);
blorp_Stream* blorp_stream_filter_map(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_int(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_int8(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_int16(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_int32(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_int64(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_uint8(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_uint16(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_uint32(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_uint64(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_float(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_bool(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_char(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_filter_map_f32(blorp_Stream* inner, blorp_Closure* func);
#ifdef __FLT16_MAX__
blorp_Stream* blorp_stream_filter_map_f16(blorp_Stream* inner, blorp_Closure* func);
#endif
blorp_Stream* blorp_stream_filter_map_nullable(blorp_Stream* inner, blorp_Closure* func);
blorp_Stream* blorp_stream_take(blorp_Stream* inner, long n);
blorp_Stream* blorp_stream_drop(blorp_Stream* inner, long n);
blorp_Stream* blorp_stream_take_while(blorp_Stream* inner, blorp_Closure* pred);
blorp_Stream* blorp_stream_enumerate(blorp_Stream* inner);
blorp_List* blorp_stream_collect(blorp_Stream* stream);
blorp_FileListResult blorp_fallible_stream_collect_file_raw(blorp_FallibleStream* stream, uint8_t storage_mode, int16_t elem_size);
blorp_FileValueResult blorp_fallible_stream_fold_file_raw(blorp_FallibleStream* stream, void* init, blorp_Closure* func, bool acc_is_rc);
blorp_FileIntResult blorp_fallible_stream_count_file_raw(blorp_FallibleStream* stream);
blorp_FileValueResult blorp_fallible_stream_find_file_raw(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_nullable(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_int(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_int8(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_int16(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_int32(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_int64(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_uint8(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_uint16(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_uint32(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_uint64(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_float(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_bool(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_char(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileValueResult blorp_fallible_stream_find_file_raw_f32(blorp_FallibleStream* stream, blorp_Closure* pred);
#ifdef __FLT16_MAX__
blorp_FileValueResult blorp_fallible_stream_find_file_raw_f16(blorp_FallibleStream* stream, blorp_Closure* pred);
#endif
blorp_FileBoolResult blorp_fallible_stream_any_file_raw(blorp_FallibleStream* stream, blorp_Closure* pred);
blorp_FileBoolResult blorp_fallible_stream_all_file_raw(blorp_FallibleStream* stream, blorp_Closure* pred);
void* blorp_stream_fold(blorp_Stream* stream, void* init, blorp_Closure* func, bool acc_is_rc);
long blorp_stream_count(blorp_Stream* stream);
void blorp_stream_for_each(blorp_Stream* stream, blorp_Closure* func);
bool blorp_stream_find_raw(blorp_Stream* stream, blorp_Closure* pred, void** out);
blorp_Option* blorp_stream_find(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Int blorp_stream_find_int(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Int8 blorp_stream_find_int8(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Int16 blorp_stream_find_int16(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Int32 blorp_stream_find_int32(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Int64 blorp_stream_find_int64(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_UInt8 blorp_stream_find_uint8(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_UInt16 blorp_stream_find_uint16(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_UInt32 blorp_stream_find_uint32(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_UInt64 blorp_stream_find_uint64(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Float blorp_stream_find_float(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Bool blorp_stream_find_bool(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Char blorp_stream_find_char(blorp_Stream* stream, blorp_Closure* pred);
blorp_StackOption_Float32 blorp_stream_find_f32(blorp_Stream* stream, blorp_Closure* pred);
#ifdef __FLT16_MAX__
blorp_StackOption_Float16 blorp_stream_find_f16(blorp_Stream* stream, blorp_Closure* pred);
#endif
void* blorp_stream_find_nullable(blorp_Stream* stream, blorp_Closure* pred);
bool blorp_stream_any(blorp_Stream* stream, blorp_Closure* pred);
bool blorp_stream_all(blorp_Stream* stream, blorp_Closure* pred);
bool blorp_stream_next_raw(blorp_Stream* stream, void** out);
void blorp_stream_release_pulled_if_owned(blorp_Stream* stream, void* value);

// Parallel List Ops
blorp_List* blorp_map_parallel(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_parallel(blorp_List* list, blorp_Closure* pred);
blorp_List* blorp_filter_map_parallel(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_int(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_int8(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_int16(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_int32(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_int64(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_uint8(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_uint16(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_uint32(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_uint64(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_float(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_bool(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_char(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_map_parallel_f32(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
#ifdef __FLT16_MAX__
blorp_List* blorp_filter_map_parallel_f16(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
#endif
blorp_List* blorp_filter_map_parallel_nullable(blorp_List* list, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
void* blorp_fold_parallel(blorp_List* list, void* init, blorp_Closure* f, int acc_is_rc);
void* blorp_fold_parallel_ordered(blorp_List* list, void* init, blorp_Closure* f, int acc_is_rc);
blorp_List* blorp_zip_parallel(blorp_List* list_a, blorp_List* list_b, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_map_parallel_with(blorp_List* list, blorp_Closure* f, long threads, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_List* blorp_filter_parallel_with(blorp_List* list, blorp_Closure* pred, long threads);
void* blorp_fold_parallel_with(blorp_List* list, void* init, blorp_Closure* f, long threads, int acc_is_rc);
void* blorp_fold_parallel_ordered_with(blorp_List* list, void* init, blorp_Closure* f, long threads, int acc_is_rc);
blorp_List* blorp_zip_parallel_with(blorp_List* list_a, blorp_List* list_b, blorp_Closure* f, long threads, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);

// Sequential list HOFs are synthesized as Core IR.
// (removed blorp_list_concat — now IR intrinsic)
// (removed blorp_list_reverse — now IR intrinsic)
// (removed blorp_list_tail — now IR intrinsic)
// (removed blorp_list_flatten — now IR intrinsic)
// (removed blorp_list_take — now IR intrinsic)
blorp_List* blorp_list_drop(blorp_List* list, long n);
blorp_Vector* blorp_vector_zip(blorp_Vector* a, blorp_Vector* b);
// (removed blorp_list_zip — now IR intrinsic)

// Vector HOFs / Parallel Vector Ops
blorp_Vector* blorp_vector_map(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc);
blorp_Vector* blorp_matrix_map(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_matrix_map_indexed(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_matrix_zip_map(blorp_Vector* arr_a, blorp_Vector* arr_b, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_vmap_parallel(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_vmap_indexed_parallel(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_vzip_parallel(blorp_Vector* arr_a, blorp_Vector* arr_b, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_mmap_parallel(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_mmap_indexed_parallel(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_mzip_parallel(blorp_Vector* arr_a, blorp_Vector* arr_b, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_mzip_indexed_parallel(blorp_Vector* arr_a, blorp_Vector* arr_b, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);
blorp_Vector* blorp_mmap_flat_indexed_parallel(blorp_Vector* arr, blorp_Closure* f, long result_elem_is_rc, uint8_t result_storage_mode, int16_t result_elem_size, uint8_t result_value_encoding);

// Math Builtins
long blorp_abs(long x);
long blorp_min(long a, long b);
long blorp_max(long a, long b);
double blorp_float_abs(double x);
double blorp_float_min(double a, double b);
double blorp_float_max(double a, double b);
long blorp_round(double x);
long blorp_is_nan(double x);
long blorp_is_inf(double x);
long blorp_is_finite(double x);
double blorp_infinity(void);
double blorp_neg_infinity(void);
double blorp_nan_value(void);

// Random
void blorp_seed_random(long seed);
long blorp_random_int(long min_val, long max_val);
double blorp_random_float(void);
blorp_Bytes* blorp_crypto_random_bytes(long n);

// Time
long blorp_now_us(void);
long blorp_black_box_int(long value);
double blorp_black_box_float(double value);
long blorp_time_now(void);
long blorp_time_to_year(long us);
long blorp_time_to_month(long us);
long blorp_time_to_day(long us);
long blorp_time_to_hour(long us);
long blorp_time_to_minute(long us);
long blorp_time_to_second(long us);
long blorp_time_to_weekday(long us);
long blorp_time_from_parts(long year, long month, long day, long hour, long minute, long second);
blorp_String* blorp_time_format(long us, const blorp_String* fmt);
blorp_StackOption_Int blorp_time_parse(const blorp_String* s, const blorp_String* fmt);
blorp_StackOption_Int blorp_time_from_iso(const blorp_String* s);

// Tuple / Closure
blorp_Tuple* blorp_tuple_new(long arity, ...);
blorp_Closure* blorp_closure_new(void* func, void* env);
blorp_Closure* blorp_closure_new_inline(void* func, int n);
static inline int blorp_closure_env_is_inline(blorp_Closure* c) {
    return c->env == (void*)((char*)c + sizeof(blorp_Closure));
}

// Fixed-Point
blorp_Fixed* blorp_fixed_raw(long value, int scale, int precision);
long blorp_pow10(int n);
blorp_Fixed* blorp_fixed_new(double value, int scale, int precision);
blorp_Fixed* blorp_fixed_from_int(long value, int scale, int precision);
blorp_Fixed* blorp_fixed_add(blorp_Fixed* a, blorp_Fixed* b);
blorp_Fixed* blorp_fixed_sub(blorp_Fixed* a, blorp_Fixed* b);
blorp_Fixed* blorp_fixed_mul(blorp_Fixed* a, blorp_Fixed* b);
blorp_Fixed* blorp_fixed_div(blorp_Fixed* a, blorp_Fixed* b);
// neg, round_to, to_int, get_scale, get_precision → IR intrinsics
bool blorp_fixed_eq(blorp_Fixed* a, blorp_Fixed* b);
bool blorp_fixed_lt(blorp_Fixed* a, blorp_Fixed* b);
bool blorp_fixed_le(blorp_Fixed* a, blorp_Fixed* b);
bool blorp_fixed_gt(blorp_Fixed* a, blorp_Fixed* b);
bool blorp_fixed_ge(blorp_Fixed* a, blorp_Fixed* b);
blorp_String* blorp_fixed_to_string(blorp_Fixed* f);
double blorp_fixed_to_float(blorp_Fixed* f);

// String Operations (Extended)
blorp_String* blorp_substring(const blorp_String* s, long start, long len);
// (removed blorp_starts_with — now IR intrinsic)
// (removed blorp_ends_with — now IR intrinsic)
// (removed blorp_contains [string version] — now IR intrinsic)
// (removed blorp_index_of [string version] — now IR intrinsic)
// (removed blorp_split — now std source)
// (removed blorp_join — now std source)
// (removed blorp_trim — now IR intrinsic)
// (removed blorp_replace — now std source)
blorp_String* blorp_upper(const blorp_String* s);
blorp_String* blorp_lower(const blorp_String* s);
// (removed blorp_capitalize — now IR intrinsic)
// (removed blorp_equal_ignore_case — now std source)
// (removed blorp_title_case — now IR intrinsic)
// (removed blorp_string_repeat — now IR intrinsic)
blorp_String* blorp_url_encode(const blorp_String* s);
blorp_String* blorp_url_decode(const blorp_String* s);
blorp_String* blorp_html_escape(const blorp_String* s);
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
long blorp_codepoint_length(const blorp_String* s);
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
blorp_List* blorp_string_codepoints(const blorp_String* s);
blorp_String* blorp_codepoint_reverse(const blorp_String* s);
// (removed blorp_split_n — now std source)
// (removed blorp_replace_first — now std source)
// (removed blorp_last_index_of — now IR intrinsic)
// (removed blorp_trim_chars — now IR intrinsic)
// (removed blorp_take_right — now IR intrinsic)
// (removed blorp_drop_right — now IR intrinsic)
// (removed blorp_center — now IR intrinsic)

// String analysis builtins
blorp_List* blorp_string_chars(const blorp_String* s);
// (removed blorp_string_is_numeric — now IR intrinsic)
// (removed blorp_string_is_ascii — now IR intrinsic)
// (removed blorp_string_is_blank — now IR intrinsic)
// (removed blorp_string_is_lower — now IR intrinsic)
// (removed blorp_string_is_upper — now IR intrinsic)
// (removed blorp_string_hamming — now IR intrinsic)
// (removed blorp_string_common_prefix — now IR intrinsic)
long blorp_string_levenshtein(const blorp_String* a, const blorp_String* b);
blorp_String* blorp_string_lcs(const blorp_String* a, const blorp_String* b);

// Regex
blorp_Result* blorp_regex_test(const blorp_String* pattern, const blorp_String* text);
blorp_Result* blorp_regex_find(const blorp_String* pattern, const blorp_String* text);
blorp_Result* blorp_regex_replace_all(const blorp_String* pattern, const blorp_String* replacement, const blorp_String* text);
blorp_Result* blorp_regex_find_all(const blorp_String* pattern, const blorp_String* text);

// StringSlice (most ops now IR intrinsics)
blorp_StringSlice* blorp_slice_alloc(blorp_String* source, long start, long len);

// Filesystem
blorp_Result* blorp_read_file(const blorp_String* path);
blorp_Result* blorp_write_file(const blorp_String* path, const blorp_String* content);
blorp_Result* blorp_read_bytes(const blorp_String* path);
blorp_Result* blorp_write_bytes(const blorp_String* path, const blorp_Bytes* content);
blorp_List* blorp_read_all_lines(const blorp_String* path);
// (removed blorp_write_lines — now IR intrinsic)
bool blorp_append_file(const blorp_String* path, const blorp_String* content);
blorp_Result* blorp_for_each_line(const blorp_String* path, blorp_Closure* callback);
blorp_Result* blorp_for_each_chunk(const blorp_String* path, long chunk_size, blorp_Closure* callback);
bool blorp_file_exists(const blorp_String* path);
blorp_FileOpenReaderResult blorp_file_open_read_raw(const blorp_String* path);
blorp_FileOpenWriterResult blorp_file_open_write_raw(const blorp_String* path);
blorp_FileOpenWriterResult blorp_file_open_append_raw(const blorp_String* path);
blorp_FileOpenResult blorp_file_open_read_write_raw(const blorp_String* path);
blorp_FileStringResult blorp_file_read_text_reader_raw(const blorp_FileReader* reader);
blorp_FileBytesResult blorp_file_read_bytes_reader_raw(const blorp_FileReader* reader);
blorp_FileBytesResult blorp_file_read_chunk_reader_raw(const blorp_FileReader* reader, long max_bytes);
blorp_FileIntResult blorp_file_count_lines_reader_raw(const blorp_FileReader* reader);
blorp_FileVoidResult blorp_file_write_text_writer_raw(blorp_FileWriter* writer, const blorp_String* text);
blorp_FileVoidResult blorp_file_write_bytes_writer_raw(blorp_FileWriter* writer, const blorp_Bytes* bytes);
blorp_FileIntResult blorp_file_write_chunk_writer_raw(blorp_FileWriter* writer, const blorp_Bytes* bytes);
blorp_FileStringResult blorp_file_read_text_file_raw(const blorp_File* file);
blorp_FileBytesResult blorp_file_read_bytes_file_raw(const blorp_File* file);
blorp_FileBytesResult blorp_file_read_chunk_file_raw(const blorp_File* file, long max_bytes);
blorp_FileIntResult blorp_file_count_lines_file_raw(const blorp_File* file);
blorp_FileVoidResult blorp_file_write_text_file_raw(blorp_File* file, const blorp_String* text);
blorp_FileVoidResult blorp_file_write_bytes_file_raw(blorp_File* file, const blorp_Bytes* bytes);
blorp_FileIntResult blorp_file_write_chunk_file_raw(blorp_File* file, const blorp_Bytes* bytes);
void blorp_file_close_reader(blorp_FileReader* reader);
void blorp_file_close_writer(blorp_FileWriter* writer);
void blorp_file_close(blorp_File* file);
bool blorp_is_directory(const blorp_String* path);
blorp_List* blorp_list_dir(const blorp_String* path);
long blorp_exec(const blorp_String* command);
blorp_String* blorp_getenv(const blorp_String* name);
blorp_String* blorp_getenv_nullable(const blorp_String* name);
bool blorp_setenv(const blorp_String* name, const blorp_String* value);

// Memory Stats / Profiling
blorp_MemStats* blorp_get_mem_stats(void);
void blorp_reset_mem_stats(void);
blorp_SchedulerStats* blorp_get_scheduler_stats(void);
void blorp_reset_scheduler_stats(void);
void blorp_profile_enable(void);
void blorp_profile_start(const char* func_name);
void blorp_profile_end(const char* func_name);
void blorp_profile_report(void);

// Debug
void blorp_debug_log_msg(blorp_String* s);
void blorp_debug_info(blorp_String* s);
void blorp_debug_warn(blorp_String* s);
void blorp_debug_error(blorp_String* s);
void blorp_debug_set_log_level(long level);

// System / Filesystem Ops
blorp_String* blorp_getcwd(void);
long blorp_mkdir(const blorp_String* path);
long blorp_remove_file(const blorp_String* path);
long blorp_remove_dir(const blorp_String* path);
long blorp_rename(const blorp_String* from, const blorp_String* to);
void* blorp_file_size(const blorp_String* path);
void* blorp_file_modified(const blorp_String* path);
blorp_String* blorp_temp_dir(void);
void* blorp_mkstemp_path(const blorp_String* prefix);
// (removed blorp_walk_dir — now IR intrinsic)
void* blorp_exec_output(const blorp_String* cmd);
void* blorp_process_run(const blorp_String* program, const blorp_List* args);
void* blorp_process_shell(const blorp_String* command);

// Hashing / Crypto
long blorp_hash_int(long k);
long blorp_hash_string(blorp_String* s);
long blorp_hash_float(double d);
long blorp_hash_combine(long seed, long value);
long blorp_hash(blorp_String* s);
long blorp_hash_bytes(blorp_String* b);
blorp_String* blorp_sha256(blorp_String* s);
blorp_String* blorp_md5(blorp_String* s);
blorp_String* blorp_sha1(blorp_String* s);
blorp_String* blorp_sha512(blorp_String* s);
long blorp_crc32(blorp_String* s);
blorp_String* blorp_sha256_bytes(blorp_String* b);
blorp_String* blorp_md5_bytes(blorp_String* b);
blorp_String* blorp_sha1_bytes(blorp_String* b);
blorp_String* blorp_sha512_bytes(blorp_String* b);
long blorp_crc32_bytes(blorp_String* b);
blorp_String* blorp_hmac_sha256(blorp_String* key, blorp_String* msg);

// SIMD Vector Operations (non-static in runtime.o)
blorp_Vector* blorp_simd_vector_op(int op, int elem_type, blorp_Vector* a, blorp_Vector* b);
blorp_Vector* blorp_simd_vector_scalar_op_f64(int op, const blorp_Vector* v, double scalar);
blorp_Vector* blorp_simd_vector_scalar_op_rev_f64(int op, const blorp_Vector* v, double scalar);
blorp_Vector* blorp_simd_vector_op_f64_cow(int op, blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_scalar_op_f64_cow(int op, blorp_Vector* v, double scalar);
blorp_Vector* blorp_simd_vector_op_f32_cow(int op, blorp_Vector* a, const blorp_Vector* b);
blorp_Vector* blorp_simd_vector_scalar_op_f32_cow(int op, blorp_Vector* v, float scalar);

// Container release helpers (non-static in runtime.o)
void blorp_elem_release_fn(void* p);
void blorp_list_set_elem_release(blorp_List* list, void (*release_fn)(void*));
void blorp_list_init_elem_release(blorp_List* list, void (*release_fn)(void*));
void blorp_vector_set_elem_release(blorp_Vector* v, void (*release_fn)(void*));
void blorp_vector_init_elem_release(blorp_Vector* v, void (*release_fn)(void*));
void blorp_dict_set_value_release(blorp_Dict* dict, void (*release_fn)(void*));
void blorp_channel_init_elem_release(void* c, void (*release_fn)(void*));

// Memory allocation
void* blorp_malloc_checked(size_t size);

// Option equality (called by codegen for == on Option types)
long blorp_option_eq(void* a, void* b);
long blorp_option_eq_string(void* a, void* b);
long blorp_option_eq_float(void* a, void* b);

// Result equality (called by codegen for == on Result types)
long blorp_result_eq(void* a, void* b);
long blorp_result_eq_string(void* a, void* b);
long blorp_result_eq_float(void* a, void* b);

// Collection equality — consuming (releases both args after comparison)
long blorp_list_eq(void* a, void* b);
long blorp_list_eq_string(void* a, void* b);
long blorp_list_eq_float(void* a, void* b);
long blorp_dict_eq(void* a, void* b);
long blorp_dict_eq_string_value(void* a, void* b);
long blorp_dict_eq_float_value(void* a, void* b);
long blorp_set_eq(void* a, void* b);

// Result to_string helpers (called by codegen for string interpolation/to_string)
blorp_String* blorp_result_to_string_int(void* r);
blorp_String* blorp_result_to_string_int_string(void* r);
blorp_String* blorp_result_to_string_string_int(void* r);
blorp_String* blorp_result_to_string_string_string(void* r);

// Tuple destructor (needed by blorp_tuple_set_rc inline)
void blorp_tuple_destructor(void* obj);

// Signal handling
void blorp_signal_on(long signum, blorp_Closure* handler);
long blorp_signal_received(long signum);
void blorp_signal_raise(long signum);
