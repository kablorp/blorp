/* The Computer Language Benchmarks Game
   https://benchmarksgame-team.pages.debian.net/benchmarksgame/
   ASCII mandelbrot - adapted for comparison with blorp version */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 16;
    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            double cr = 2.0 * x / n - 1.5;
            double ci = 2.0 * y / n - 1.0;
            double zr = 0, zi = 0;
            int in_set = 1;
            for (int iter = 0; iter < 50; iter++) {
                double tr = zr * zr - zi * zi + cr;
                double ti = 2.0 * zr * zi + ci;
                zr = tr; zi = ti;
                if (zr * zr + zi * zi > 4.0) { in_set = 0; break; }
            }
            putchar(in_set ? '#' : '.');
        }
        putchar('\n');
    }
    return 0;
}
