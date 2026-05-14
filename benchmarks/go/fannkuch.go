// The Computer Language Benchmarks Game
// https://benchmarksgame-team.pages.debian.net/benchmarksgame/
//
// Fannkuch-redux: count max flips and compute checksum

package main

import (
	"fmt"
	"os"
	"strconv"
)

func fannkuch(n int) (int, int) {
	perm := make([]int, n)
	perm1 := make([]int, n)
	count := make([]int, n)

	for i := 0; i < n; i++ {
		perm1[i] = i
	}

	maxFlips := 0
	checksum := 0
	permCount := 0
	r := n

	for {
		for r > 1 {
			count[r-1] = r
			r--
		}

		copy(perm, perm1)
		flips := 0
		k := perm[0]
		for k != 0 {
			// Reverse perm[0..k]
			for i, j := 0, k; i < j; i, j = i+1, j-1 {
				perm[i], perm[j] = perm[j], perm[i]
			}
			flips++
			k = perm[0]
		}
		if flips > maxFlips {
			maxFlips = flips
		}
		if permCount%2 == 0 {
			checksum += flips
		} else {
			checksum -= flips
		}
		permCount++

		// Generate next permutation
		for {
			if r == n {
				fmt.Printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, maxFlips)
				return checksum, maxFlips
			}
			perm0 := perm1[0]
			for i := 0; i < r; i++ {
				perm1[i] = perm1[i+1]
			}
			perm1[r] = perm0
			count[r]--
			if count[r] > 0 {
				break
			}
			r++
		}
	}
}

func main() {
	n := 10
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	fannkuch(n)
}
