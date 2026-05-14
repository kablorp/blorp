#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SIZE 1000
#define ITERATIONS 10000

/* Match blorp's Vector runtime: heap-allocated arrays with fresh
   allocation per vadd/scale operation (no in-place reuse). */

static long *vector_new(int len) {
    long *v = malloc(len * sizeof(long));
    return v;
}

static long *vadd_int(const long *a, const long *b, int len) {
    long *result = vector_new(len);
    for (int i = 0; i < len; i++) {
        result[i] = a[i] + b[i];
    }
    return result;
}

static long *scale_int(const long *v, long scalar, int len) {
    long *result = vector_new(len);
    for (int i = 0; i < len; i++) {
        result[i] = v[i] * scalar;
    }
    return result;
}

static long sum_int(const long *v, int len) {
    long sum = 0;
    for (int i = 0; i < len; i++) {
        sum += v[i];
    }
    return sum;
}

int main(void) {
    long *arr1 = vector_new(SIZE);
    long *arr2 = vector_new(SIZE);
    for (int i = 0; i < SIZE; i++) {
        arr1[i] = i;
        arr2[i] = i * 2;
    }

    long final_sum = 0;
    for (int iter = 0; iter < ITERATIONS; iter++) {
        long *combined = vadd_int(arr1, arr2, SIZE);
        long *scaled = scale_int(combined, 3, SIZE);
        final_sum += sum_int(scaled, SIZE);
        free(scaled);
        free(combined);
    }

    printf("Completed %d iterations, final sum: %ld\n", ITERATIONS, final_sum);
    free(arr1);
    free(arr2);
    return 0;
}
