// N-body planetary simulation benchmark.
//
// Uses the same struct-of-arrays layout as benchmarks/blorp/nbody.brp so the
// cross-language row compares the same source-level data movement.

package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

const (
	solarMass   = 4 * math.Pi * math.Pi
	daysPerYear = 365.24
	nBodies     = 5
)

func initBodies() ([]float64, []float64, []float64, []float64, []float64, []float64, []float64) {
	bx := make([]float64, nBodies)
	by := make([]float64, nBodies)
	bz := make([]float64, nBodies)
	bvx := make([]float64, nBodies)
	bvy := make([]float64, nBodies)
	bvz := make([]float64, nBodies)
	bmass := make([]float64, nBodies)

	bmass[0] = solarMass

	bx[1] = 4.841431442464721
	by[1] = -1.1603200440274284
	bz[1] = -0.10362204447112311
	bvx[1] = 0.001660076642744037 * daysPerYear
	bvy[1] = 0.007699011184197404 * daysPerYear
	bvz[1] = -0.0000690460016972063 * daysPerYear
	bmass[1] = 0.0009547919384243266 * solarMass

	bx[2] = 8.34336671824458
	by[2] = 4.124798564124305
	bz[2] = -0.4035234171143214
	bvx[2] = -0.002767425107268624 * daysPerYear
	bvy[2] = 0.004998528012349172 * daysPerYear
	bvz[2] = 0.00002304172975737639 * daysPerYear
	bmass[2] = 0.0002858859806661308 * solarMass

	bx[3] = 12.894369562139131
	by[3] = -15.111151401698631
	bz[3] = -0.22330757889265573
	bvx[3] = 0.002964601375647616 * daysPerYear
	bvy[3] = 0.0023784717395948095 * daysPerYear
	bvz[3] = -0.00002965895685402376 * daysPerYear
	bmass[3] = 0.00004366244043351563 * solarMass

	bx[4] = 15.379697114850917
	by[4] = -25.919314609987964
	bz[4] = 0.17925877295037118
	bvx[4] = 0.0026806777249038932 * daysPerYear
	bvy[4] = 0.001628241700382423 * daysPerYear
	bvz[4] = -0.00009515922545197159 * daysPerYear
	bmass[4] = 0.00005151389020466115 * solarMass

	return bx, by, bz, bvx, bvy, bvz, bmass
}

func offsetMomentum(bvx, bvy, bvz, bmass []float64) {
	px, py, pz := 0.0, 0.0, 0.0
	for i := 0; i < len(bmass); i++ {
		px += bvx[i] * bmass[i]
		py += bvy[i] * bmass[i]
		pz += bvz[i] * bmass[i]
	}
	bvx[0] = -px / solarMass
	bvy[0] = -py / solarMass
	bvz[0] = -pz / solarMass
}

func energy(bx, by, bz, bvx, bvy, bvz, bmass []float64) float64 {
	e := 0.0
	for i := 0; i < len(bx); i++ {
		e += 0.5 * bmass[i] * (bvx[i]*bvx[i] + bvy[i]*bvy[i] + bvz[i]*bvz[i])
		for j := i + 1; j < len(bx); j++ {
			dx := bx[i] - bx[j]
			dy := by[i] - by[j]
			dz := bz[i] - bz[j]
			dist := math.Sqrt(dx*dx + dy*dy + dz*dz)
			e -= bmass[i] * bmass[j] / dist
		}
	}
	return e
}

func advance(bx, by, bz, bvx, bvy, bvz, bmass []float64, dt float64) {
	for i := 0; i < len(bx); i++ {
		for j := i + 1; j < len(bx); j++ {
			dx := bx[i] - bx[j]
			dy := by[i] - by[j]
			dz := bz[i] - bz[j]
			distSq := dx*dx + dy*dy + dz*dz
			dist := math.Sqrt(distSq)
			mag := dt / (distSq * dist)
			bvx[i] -= dx * bmass[j] * mag
			bvy[i] -= dy * bmass[j] * mag
			bvz[i] -= dz * bmass[j] * mag
			bvx[j] += dx * bmass[i] * mag
			bvy[j] += dy * bmass[i] * mag
			bvz[j] += dz * bmass[i] * mag
		}
	}
	for i := 0; i < len(bx); i++ {
		bx[i] += dt * bvx[i]
		by[i] += dt * bvy[i]
		bz[i] += dt * bvz[i]
	}
}

func main() {
	n := 1000
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	bx, by, bz, bvx, bvy, bvz, bmass := initBodies()
	offsetMomentum(bvx, bvy, bvz, bmass)
	fmt.Printf("%.9f\n", energy(bx, by, bz, bvx, bvy, bvz, bmass))
	for i := 0; i < n; i++ {
		advance(bx, by, bz, bvx, bvy, bvz, bmass, 0.01)
	}
	fmt.Printf("%.9f\n", energy(bx, by, bz, bvx, bvy, bvz, bmass))
}
