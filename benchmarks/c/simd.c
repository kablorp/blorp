#include <stdio.h>
#include <stdlib.h>

#define N 16
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

static void make_f64(double *out, double offset) {
    for (int i = 0; i < N; i++) {
        out[i] = (double)i + offset;
    }
}

static void make_i64(long *out, long offset) {
    for (int i = 0; i < N; i++) {
        out[i] = (long)i + offset;
    }
}

static double *add_f64(const double *a, const double *b) {
    double *result = malloc((size_t)N * sizeof(double));
    for (int i = 0; i < N; i++) {
        result[i] = a[i] + b[i];
    }
    return result;
}

static long *add_i64(const long *a, const long *b) {
    long *result = malloc((size_t)N * sizeof(long));
    for (int i = 0; i < N; i++) {
        result[i] = a[i] + b[i];
    }
    return result;
}

static double *mul_f64(const double *a, const double *b) {
    double *result = malloc((size_t)N * sizeof(double));
    for (int i = 0; i < N; i++) {
        result[i] = a[i] * b[i];
    }
    return result;
}

static long *mul_i64(const long *a, const long *b) {
    long *result = malloc((size_t)N * sizeof(long));
    for (int i = 0; i < N; i++) {
        result[i] = a[i] * b[i];
    }
    return result;
}

static double sum_f64(const double *a) {
    double total = 0.0;
    for (int i = 0; i < N; i++) {
        total += a[i];
    }
    return total;
}

static long sum_i64(const long *a) {
    long total = 0;
    for (int i = 0; i < N; i++) {
        total += a[i];
    }
    return total;
}

static double dot_f64(const double *a, const double *b) {
    double total = 0.0;
    for (int i = 0; i < N; i++) {
        total += a[i] * b[i];
    }
    return total;
}

static long dot_i64(const long *a, const long *b) {
    long total = 0;
    for (int i = 0; i < N; i++) {
        total += a[i] * b[i];
    }
    return total;
}

static long bench_add_f64(void) {
    double a[N];
    double b[N];
    long checksum = 0;
    make_f64(a, 1.0);
    make_f64(b, 2.0);

    for (int i = 0; i < ADD_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        double *result = add_f64(a, b);
        checksum += (long)sum_f64(result);
        free(result);
    }

    return checksum;
}

static long bench_add_i64(void) {
    long a[N];
    long b[N];
    long checksum = 0;
    make_i64(a, 1);
    make_i64(b, 2);

    for (int i = 0; i < ADD_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        long *result = add_i64(a, b);
        checksum += sum_i64(result);
        free(result);
    }

    return checksum;
}

static long bench_sum_f64(void) {
    double a[N];
    long checksum = 0;
    make_f64(a, 1.0);

    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        checksum += (long)sum_f64(a);
    }

    return checksum;
}

static long bench_sum_i64(void) {
    long a[N];
    long checksum = 0;
    make_i64(a, 1);

    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        checksum += sum_i64(a);
    }

    return checksum;
}

static long bench_dot_f64(void) {
    double a[N];
    double b[N];
    long checksum = 0;
    make_f64(a, 1.0);
    make_f64(b, 2.0);

    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        checksum += (long)dot_f64(a, b);
    }

    return checksum;
}

static long bench_dot_i64(void) {
    long a[N];
    long b[N];
    long checksum = 0;
    make_i64(a, 1);
    make_i64(b, 2);

    for (int i = 0; i < REDUCE_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        checksum += dot_i64(a, b);
    }

    return checksum;
}

static long bench_mul_f64(void) {
    double a[N];
    double b[N];
    long checksum = 0;
    make_f64(a, 1.0);
    make_f64(b, 2.0);

    for (int i = 0; i < MUL_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        double *result = mul_f64(a, b);
        checksum += (long)sum_f64(result);
        free(result);
    }

    return checksum;
}

static long bench_mul_i64(void) {
    long a[N];
    long b[N];
    long checksum = 0;
    make_i64(a, 1);
    make_i64(b, 2);

    for (int i = 0; i < MUL_ITERS; i++) {
        black_box_ptr(a);
        black_box_ptr(b);
        long *result = mul_i64(a, b);
        checksum += sum_i64(result);
        free(result);
    }

    return checksum;
}

int main(void) {
    printf("add_f64: %ld\n", bench_add_f64());
    printf("add_i64: %ld\n", bench_add_i64());
    printf("sum_f64: %ld\n", bench_sum_f64());
    printf("sum_i64: %ld\n", bench_sum_i64());
    printf("dot_f64: %ld\n", bench_dot_f64());
    printf("dot_i64: %ld\n", bench_dot_i64());
    printf("mul_f64: %ld\n", bench_mul_f64());
    printf("mul_i64: %ld\n", bench_mul_i64());
    return 0;
}
