/* N-body planetary simulation benchmark.
 *
 * Uses the same struct-of-arrays layout as benchmarks/blorp/nbody.brp so the
 * cross-language row compares the same source-level data movement.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#define PI 3.141592653589793
#define SOLAR_MASS (4 * PI * PI)
#define DAYS_PER_YEAR 365.24
#define NBODIES 5

static double bx[NBODIES];
static double by[NBODIES];
static double bz[NBODIES];
static double bvx[NBODIES];
static double bvy[NBODIES];
static double bvz[NBODIES];
static double bmass[NBODIES];

static void init_bodies(void) {
    for (int i = 0; i < NBODIES; i++) {
        bx[i] = by[i] = bz[i] = 0.0;
        bvx[i] = bvy[i] = bvz[i] = 0.0;
        bmass[i] = 0.0;
    }

    bmass[0] = SOLAR_MASS;

    bx[1] = 4.841431442464721;
    by[1] = -1.1603200440274284;
    bz[1] = -0.10362204447112311;
    bvx[1] = 0.001660076642744037 * DAYS_PER_YEAR;
    bvy[1] = 0.007699011184197404 * DAYS_PER_YEAR;
    bvz[1] = -0.0000690460016972063 * DAYS_PER_YEAR;
    bmass[1] = 0.0009547919384243266 * SOLAR_MASS;

    bx[2] = 8.34336671824458;
    by[2] = 4.124798564124305;
    bz[2] = -0.4035234171143214;
    bvx[2] = -0.002767425107268624 * DAYS_PER_YEAR;
    bvy[2] = 0.004998528012349172 * DAYS_PER_YEAR;
    bvz[2] = 0.00002304172975737639 * DAYS_PER_YEAR;
    bmass[2] = 0.0002858859806661308 * SOLAR_MASS;

    bx[3] = 12.894369562139131;
    by[3] = -15.111151401698631;
    bz[3] = -0.22330757889265573;
    bvx[3] = 0.002964601375647616 * DAYS_PER_YEAR;
    bvy[3] = 0.0023784717395948095 * DAYS_PER_YEAR;
    bvz[3] = -0.00002965895685402376 * DAYS_PER_YEAR;
    bmass[3] = 0.00004366244043351563 * SOLAR_MASS;

    bx[4] = 15.379697114850917;
    by[4] = -25.919314609987964;
    bz[4] = 0.17925877295037118;
    bvx[4] = 0.0026806777249038932 * DAYS_PER_YEAR;
    bvy[4] = 0.001628241700382423 * DAYS_PER_YEAR;
    bvz[4] = -0.00009515922545197159 * DAYS_PER_YEAR;
    bmass[4] = 0.00005151389020466115 * SOLAR_MASS;
}

static void offset_momentum(void) {
    double px = 0.0, py = 0.0, pz = 0.0;
    for (int i = 0; i < NBODIES; i++) {
        px += bvx[i] * bmass[i];
        py += bvy[i] * bmass[i];
        pz += bvz[i] * bmass[i];
    }
    bvx[0] = -px / SOLAR_MASS;
    bvy[0] = -py / SOLAR_MASS;
    bvz[0] = -pz / SOLAR_MASS;
}

static double energy(void) {
    double e = 0.0;
    for (int i = 0; i < NBODIES; i++) {
        e += 0.5 * bmass[i] * (bvx[i] * bvx[i] + bvy[i] * bvy[i] + bvz[i] * bvz[i]);
        for (int j = i + 1; j < NBODIES; j++) {
            double dx = bx[i] - bx[j];
            double dy = by[i] - by[j];
            double dz = bz[i] - bz[j];
            double dist = sqrt(dx * dx + dy * dy + dz * dz);
            e -= bmass[i] * bmass[j] / dist;
        }
    }
    return e;
}

static void advance(double dt) {
    for (int i = 0; i < NBODIES; i++) {
        for (int j = i + 1; j < NBODIES; j++) {
            double dx = bx[i] - bx[j];
            double dy = by[i] - by[j];
            double dz = bz[i] - bz[j];
            double dist_sq = dx * dx + dy * dy + dz * dz;
            double dist = sqrt(dist_sq);
            double mag = dt / (dist_sq * dist);
            bvx[i] -= dx * bmass[j] * mag;
            bvy[i] -= dy * bmass[j] * mag;
            bvz[i] -= dz * bmass[j] * mag;
            bvx[j] += dx * bmass[i] * mag;
            bvy[j] += dy * bmass[i] * mag;
            bvz[j] += dz * bmass[i] * mag;
        }
    }
    for (int i = 0; i < NBODIES; i++) {
        bx[i] += dt * bvx[i];
        by[i] += dt * bvy[i];
        bz[i] += dt * bvz[i];
    }
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1000;
    init_bodies();
    offset_momentum();
    printf("%.9f\n", energy());
    for (int i = 0; i < n; i++) advance(0.01);
    printf("%.9f\n", energy());
    return 0;
}
