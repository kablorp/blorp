/* The Computer Language Benchmarks Game
   https://benchmarksgame-team.pages.debian.net/benchmarksgame/
   contributed by Sebastien Loisel

   Allocation contract intentionally mirrors benchmarks/blorp/spectral_norm.brp:
   every matrix-vector multiply returns a fresh vector. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double A(int i, int j) {
    return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1);
}

static double *mul_Av(int n, const double *v) {
    double *av = malloc((size_t)n * sizeof(double));
    for (int i = 0; i < n; i++) {
        double sum = 0.0;
        for (int j = 0; j < n; j++) sum += A(i, j) * v[j];
        av[i] = sum;
    }
    return av;
}

static double *mul_Atv(int n, const double *v) {
    double *atv = malloc((size_t)n * sizeof(double));
    for (int i = 0; i < n; i++) {
        double sum = 0.0;
        for (int j = 0; j < n; j++) sum += A(j, i) * v[j];
        atv[i] = sum;
    }
    return atv;
}

static double *mul_AtAv(int n, const double *v) {
    double *tmp = mul_Av(n, v);
    double *result = mul_Atv(n, tmp);
    free(tmp);
    return result;
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 500;
    double *u = malloc((size_t)n * sizeof(double));
    double *v = NULL;

    for (int i = 0; i < n; i++) u[i] = 1.0;

    for (int i = 0; i < 10; i++) {
        if (v != NULL) free(v);
        v = mul_AtAv(n, u);
        free(u);
        u = mul_AtAv(n, v);
    }

    double vBv = 0.0, vv = 0.0;
    for (int i = 0; i < n; i++) {
        vBv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    printf("%.9f\n", sqrt(vBv / vv));
    free(u);
    free(v);
    return 0;
}
