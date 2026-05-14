#include <stdio.h>

long collatz_steps(long start) {
    long n = start;
    long steps = 0;
    while (n != 1) {
        if (n % 2 == 0)
            n = n / 2;
        else
            n = n * 3 + 1;
        steps++;
    }
    return steps;
}

int main(void) {
    long total_steps = 0;
    for (long i = 1; i < 1000000; i++) {
        total_steps += collatz_steps(i);
    }
    printf("Total Collatz steps: %ld\n", total_steps);
    return 0;
}
