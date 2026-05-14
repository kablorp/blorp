/* The Computer Language Benchmarks Game
   https://benchmarksgame-team.pages.debian.net/benchmarksgame/
   contributed by Ledrug */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 7;
    int *perm = malloc(n * sizeof(int));
    int *perm1 = malloc(n * sizeof(int));
    int *count = malloc(n * sizeof(int));
    int *tmp = malloc(n * sizeof(int));

    for (int i = 0; i < n; i++) perm1[i] = i;

    int max_flips = 0, checksum = 0, r = n;
    int perm_count = 0;

    for (;;) {
        while (r > 1) { count[r - 1] = r; r--; }

        memcpy(perm, perm1, n * sizeof(int));
        int flips = 0;
        int k;
        while ((k = perm[0]) != 0) {
            int k2 = (k + 1) >> 1;
            for (int i = 0; i < k2; i++) {
                int t = perm[i];
                perm[i] = perm[k - i];
                perm[k - i] = t;
            }
            flips++;
        }

        if (flips > max_flips) max_flips = flips;
        checksum += (perm_count & 1) ? -flips : flips;
        perm_count++;

        for (;;) {
            if (r == n) goto done;
            int p0 = perm1[0];
            for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1];
            perm1[r] = p0;
            if (--count[r] > 0) break;
            r++;
        }
    }
done:
    printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, max_flips);
    free(perm); free(perm1); free(count); free(tmp);
    return 0;
}
