#include <stdio.h>

#define SIZE 1000
#define ITERATIONS 10000

static inline void black_box_ptr(const void *ptr) {
    __asm__ __volatile__("" : : "r"(ptr) : "memory");
}

int main(void) {
    long arr[SIZE];
    for (int i = 0; i < SIZE; i++) {
        arr[i] = i;
    }

    long total = 0;
    for (int iter = 0; iter < ITERATIONS; iter++) {
        black_box_ptr(arr);
        long sum = 0;
        for (int i = 0; i < SIZE; i++) {
            sum += arr[i];
        }
        total += sum;
    }

    printf("Completed %d iterations, total: %ld\n", ITERATIONS, total);
    return 0;
}
