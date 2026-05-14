// The Computer Language Benchmarks Game
// https://benchmarksgame-team.pages.debian.net/benchmarksgame/
//
// Allocation contract intentionally mirrors benchmarks/blorp/spectral_norm.brp:
// every matrix-vector multiply returns a fresh vector.

package main

import (
	"fmt"
	"math"
	"os"
	"strconv"
)

func a(i, j int) float64 {
	return 1.0 / float64((i+j)*(i+j+1)/2+i+1)
}

func multiplyAv(n int, v []float64) []float64 {
	av := make([]float64, n)
	for i := 0; i < n; i++ {
		sum := 0.0
		for j := 0; j < n; j++ {
			sum += a(i, j) * v[j]
		}
		av[i] = sum
	}
	return av
}

func multiplyAtv(n int, v []float64) []float64 {
	atv := make([]float64, n)
	for i := 0; i < n; i++ {
		sum := 0.0
		for j := 0; j < n; j++ {
			sum += a(j, i) * v[j]
		}
		atv[i] = sum
	}
	return atv
}

func multiplyAtAv(n int, v []float64) []float64 {
	u := multiplyAv(n, v)
	return multiplyAtv(n, u)
}

func main() {
	n := 500
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	u := make([]float64, n)
	for i := 0; i < n; i++ {
		u[i] = 1.0
	}

	var v []float64
	for i := 0; i < 10; i++ {
		v = multiplyAtAv(n, u)
		u = multiplyAtAv(n, v)
	}

	vBv := 0.0
	vv := 0.0
	for i := 0; i < n; i++ {
		vBv += u[i] * v[i]
		vv += v[i] * v[i]
	}

	fmt.Printf("%.9f\n", math.Sqrt(vBv/vv))
}
