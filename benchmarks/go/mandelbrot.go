// The Computer Language Benchmarks Game
// https://benchmarksgame-team.pages.debian.net/benchmarksgame/
//
// Mandelbrot set: ASCII rendering

package main

import (
	"fmt"
	"os"
	"strconv"
)

func main() {
	n := 200
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	maxIter := 50
	limit := 4.0
	for y := 0; y < n; y++ {
		ci := 2.0*float64(y)/float64(n) - 1.0
		for x := 0; x < n; x++ {
			cr := 2.0*float64(x)/float64(n) - 1.5
			zr := 0.0
			zi := 0.0
			escaped := false
			for i := 0; i < maxIter; i++ {
				tr := zr*zr - zi*zi + cr
				ti := 2.0*zr*zi + ci
				zr = tr
				zi = ti
				if zr*zr+zi*zi > limit {
					escaped = true
					break
				}
			}
			if escaped {
				fmt.Print(".")
			} else {
				fmt.Print("#")
			}
		}
		fmt.Println()
	}
}
