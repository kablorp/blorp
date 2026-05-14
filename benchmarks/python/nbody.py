import math
import sys

SOLAR_MASS = 4 * math.pi * math.pi
DAYS_PER_YEAR = 365.24
NBODIES = 5


def init_bodies():
    bx = [0.0] * NBODIES
    by = [0.0] * NBODIES
    bz = [0.0] * NBODIES
    bvx = [0.0] * NBODIES
    bvy = [0.0] * NBODIES
    bvz = [0.0] * NBODIES
    bmass = [0.0] * NBODIES

    bmass[0] = SOLAR_MASS

    bx[1] = 4.841431442464721
    by[1] = -1.1603200440274284
    bz[1] = -0.10362204447112311
    bvx[1] = 0.001660076642744037 * DAYS_PER_YEAR
    bvy[1] = 0.007699011184197404 * DAYS_PER_YEAR
    bvz[1] = -0.0000690460016972063 * DAYS_PER_YEAR
    bmass[1] = 0.0009547919384243266 * SOLAR_MASS

    bx[2] = 8.34336671824458
    by[2] = 4.124798564124305
    bz[2] = -0.4035234171143214
    bvx[2] = -0.002767425107268624 * DAYS_PER_YEAR
    bvy[2] = 0.004998528012349172 * DAYS_PER_YEAR
    bvz[2] = 0.00002304172975737639 * DAYS_PER_YEAR
    bmass[2] = 0.0002858859806661308 * SOLAR_MASS

    bx[3] = 12.894369562139131
    by[3] = -15.111151401698631
    bz[3] = -0.22330757889265573
    bvx[3] = 0.002964601375647616 * DAYS_PER_YEAR
    bvy[3] = 0.0023784717395948095 * DAYS_PER_YEAR
    bvz[3] = -0.00002965895685402376 * DAYS_PER_YEAR
    bmass[3] = 0.00004366244043351563 * SOLAR_MASS

    bx[4] = 15.379697114850917
    by[4] = -25.919314609987964
    bz[4] = 0.17925877295037118
    bvx[4] = 0.0026806777249038932 * DAYS_PER_YEAR
    bvy[4] = 0.001628241700382423 * DAYS_PER_YEAR
    bvz[4] = -0.00009515922545197159 * DAYS_PER_YEAR
    bmass[4] = 0.00005151389020466115 * SOLAR_MASS

    return bx, by, bz, bvx, bvy, bvz, bmass


def offset_momentum(bvx, bvy, bvz, bmass):
    px = py = pz = 0.0
    for i in range(NBODIES):
        px += bvx[i] * bmass[i]
        py += bvy[i] * bmass[i]
        pz += bvz[i] * bmass[i]
    bvx[0] = -px / SOLAR_MASS
    bvy[0] = -py / SOLAR_MASS
    bvz[0] = -pz / SOLAR_MASS


def energy(bx, by, bz, bvx, bvy, bvz, bmass):
    e = 0.0
    for i in range(NBODIES):
        e += 0.5 * bmass[i] * (bvx[i] * bvx[i] + bvy[i] * bvy[i] + bvz[i] * bvz[i])
        for j in range(i + 1, NBODIES):
            dx = bx[i] - bx[j]
            dy = by[i] - by[j]
            dz = bz[i] - bz[j]
            dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            e -= bmass[i] * bmass[j] / dist
    return e


def advance(bx, by, bz, bvx, bvy, bvz, bmass, dt):
    for i in range(NBODIES):
        for j in range(i + 1, NBODIES):
            dx = bx[i] - bx[j]
            dy = by[i] - by[j]
            dz = bz[i] - bz[j]
            dist_sq = dx * dx + dy * dy + dz * dz
            dist = math.sqrt(dist_sq)
            mag = dt / (dist_sq * dist)
            bvx[i] -= dx * bmass[j] * mag
            bvy[i] -= dy * bmass[j] * mag
            bvz[i] -= dz * bmass[j] * mag
            bvx[j] += dx * bmass[i] * mag
            bvy[j] += dy * bmass[i] * mag
            bvz[j] += dz * bmass[i] * mag

    for i in range(NBODIES):
        bx[i] += dt * bvx[i]
        by[i] += dt * bvy[i]
        bz[i] += dt * bvz[i]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    bx, by, bz, bvx, bvy, bvz, bmass = init_bodies()
    offset_momentum(bvx, bvy, bvz, bmass)
    print("%.9f" % energy(bx, by, bz, bvx, bvy, bvz, bmass))
    for _ in range(n):
        advance(bx, by, bz, bvx, bvy, bvz, bmass, 0.01)
    print("%.9f" % energy(bx, by, bz, bvx, bvy, bvz, bmass))


if __name__ == "__main__":
    main()
