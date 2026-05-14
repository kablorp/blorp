/* SIMD Vector Benchmark - C baseline with -O3 auto-vectorization.
 *
 * The source shape mirrors benchmarks/blorp/simd.brp: each operation family
 * runs the same iteration count and prints a deterministic checksum. The
 * outer benchmark harness owns timing.
 */
#include <stdio.h>
#include <stdlib.h>

#define N 64
#define ADD_ITERS 200000
#define REDUCE_ITERS 500000
#define MUL_ITERS 200000

static inline void black_box_ptr(const void *ptr) {
#if defined(__clang__) || defined(__GNUC__)
    __asm__ __volatile__("" : : "r"(ptr) : "memory");
#else
    (void)ptr;
#endif
}

static void make_f64(double *out, int n, double offset) {
    for (int i = 0; i < n; i++) out[i] = (double)(i % 17) + offset;
}

static void make_f32(float *out, int n, float offset) {
    for (int i = 0; i < n; i++) out[i] = (float)(i % 17) + offset;
}

static void make_i64(long *out, int n, long offset) {
    for (int i = 0; i < n; i++) out[i] = (long)(i % 17) + offset;
}

__attribute__((noinline))
static double *add_f64(const double *a, const double *b, int n) {
    double *r = malloc((size_t)n * sizeof(double));
    for (int i = 0; i < n; i++) r[i] = a[i] + b[i];
    return r;
}

__attribute__((noinline))
static float *add_f32(const float *a, const float *b, int n) {
    float *r = malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) r[i] = a[i] + b[i];
    return r;
}

__attribute__((noinline))
static long *add_i64(const long *a, const long *b, int n) {
    long *r = malloc((size_t)n * sizeof(long));
    for (int i = 0; i < n; i++) r[i] = a[i] + b[i];
    return r;
}

__attribute__((noinline))
static double *mul_f64(const double *a, const double *b, int n) {
    double *r = malloc((size_t)n * sizeof(double));
    for (int i = 0; i < n; i++) r[i] = a[i] * b[i];
    return r;
}

__attribute__((noinline))
static float *mul_f32(const float *a, const float *b, int n) {
    float *r = malloc((size_t)n * sizeof(float));
    for (int i = 0; i < n; i++) r[i] = a[i] * b[i];
    return r;
}

__attribute__((noinline))
static double sum_f64(const double *a, int n) {
    double s = 0.0;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}

__attribute__((noinline))
static float sum_f32(const float *a, int n) {
    float s = 0.0f;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}

__attribute__((noinline))
static long sum_i64(const long *a, int n) {
    long s = 0;
    for (int i = 0; i < n; i++) s += a[i];
    return s;
}

__attribute__((noinline))
static double dot_f64(const double *a, const double *b, int n) {
    double s = 0.0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

__attribute__((noinline))
static long dot_i64(const long *a, const long *b, int n) {
    long s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

static long bench_add_f64(int n) {
    double *a = calloc((size_t)n, sizeof(double));
    double *b = calloc((size_t)n, sizeof(double));
    make_f64(a, n, 1.0);
    make_f64(b, n, 2.0);
    long checksum = 0;
    for (int i = 0; i < ADD_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        double *r = add_f64(a, b, n);
        checksum += (long)sum_f64(r, n);
        free(r);
    }
    free(a);
    free(b);
    return checksum;
}

static long bench_add_f32(void) {
    float a[N], b[N];
    make_f32(a, N, 1.0f);
    make_f32(b, N, 2.0f);
    long checksum = 0;
    for (int i = 0; i < ADD_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        float *r = add_f32(a, b, N);
        checksum += (long)sum_f32(r, N);
        free(r);
    }
    return checksum;
}

static long bench_add_i64(void) {
    long a[N], b[N];
    make_i64(a, N, 1);
    make_i64(b, N, 2);
    long checksum = 0;
    for (int i = 0; i < ADD_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        long *r = add_i64(a, b, N);
        checksum += sum_i64(r, N);
        free(r);
    }
    return checksum;
}

static long bench_sum_f64(void) {
    double a[N];
    make_f64(a, N, 1.0);
    long checksum = 0;
    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        checksum += (long)sum_f64(a, N);
    }
    return checksum;
}

static long bench_sum_i64(void) {
    long a[N];
    make_i64(a, N, 1);
    long checksum = 0;
    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        checksum += sum_i64(a, N);
    }
    return checksum;
}

static long bench_dot_f64(void) {
    double a[N], b[N];
    make_f64(a, N, 1.0);
    make_f64(b, N, 2.0);
    long checksum = 0;
    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        checksum += (long)dot_f64(a, b, N);
    }
    return checksum;
}

static long bench_dot_i64(void) {
    long a[N], b[N];
    make_i64(a, N, 1);
    make_i64(b, N, 2);
    long checksum = 0;
    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        checksum += dot_i64(a, b, N);
    }
    return checksum;
}

static long bench_mul_f64(void) {
    double a[N], b[N];
    make_f64(a, N, 1.0);
    make_f64(b, N, 2.0);
    long checksum = 0;
    for (int i = 0; i < MUL_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        double *r = mul_f64(a, b, N);
        checksum += (long)sum_f64(r, N);
        free(r);
    }
    return checksum;
}

static long bench_mul_f32(void) {
    float a[N], b[N];
    make_f32(a, N, 1.0f);
    make_f32(b, N, 2.0f);
    long checksum = 0;
    for (int i = 0; i < MUL_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        float *r = mul_f32(a, b, N);
        checksum += (long)sum_f32(r, N);
        free(r);
    }
    return checksum;
}

int main(void) {
    printf("add_f64: %ld\n", bench_add_f64(N));
    printf("add_f32: %ld\n", bench_add_f32());
    printf("add_i64: %ld\n", bench_add_i64());
    printf("add_f64_4: %ld\n", bench_add_f64(4));
    printf("add_f64_16: %ld\n", bench_add_f64(16));
    printf("add_f64_64: %ld\n", bench_add_f64(64));
    printf("add_f64_256: %ld\n", bench_add_f64(256));
    printf("sum_f64: %ld\n", bench_sum_f64());
    printf("sum_i64: %ld\n", bench_sum_i64());
    printf("dot_f64: %ld\n", bench_dot_f64());
    printf("dot_i64: %ld\n", bench_dot_i64());
    printf("mul_f64: %ld\n", bench_mul_f64());
    printf("mul_f32: %ld\n", bench_mul_f32());
    return 0;
}
