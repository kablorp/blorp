package main

import "fmt"

func benchBuild(n int, iters int) map[int]int {
	var d map[int]int
	for iter := 0; iter < iters; iter++ {
		d = make(map[int]int)
		for i := 0; i < n; i++ {
			d[i] = i * 7
		}
	}
	return d
}

func benchLookupHit(d map[int]int, n int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		for i := 0; i < n; i++ {
			if v, ok := d[i]; ok {
				checksum += v
			}
		}
	}
	return checksum
}

func benchLookupMiss(d map[int]int, n int, iters int) int {
	misses := 0
	for iter := 0; iter < iters; iter++ {
		for i := n; i < n+n; i++ {
			if _, ok := d[i]; !ok {
				misses++
			}
		}
	}
	return misses
}

func benchRemove(n int, iters int) int {
	removed := 0
	for iter := 0; iter < iters; iter++ {
		d := make(map[int]int)
		for i := 0; i < n; i++ {
			d[i] = i * 7
		}
		for i := 0; i < n; i++ {
			delete(d, i)
			removed++
		}
	}
	return removed
}

func benchIterate(d map[int]int, iters int) int {
	total := 0
	for iter := 0; iter < iters; iter++ {
		for _, v := range d {
			total += v
		}
	}
	return total
}

func main() {
	const N = 10000

	d := benchBuild(N, 100)
	fmt.Println("build: done")

	hitSum := benchLookupHit(d, N, 100)
	fmt.Printf("lookup_hit checksum: %d\n", hitSum)

	missCount := benchLookupMiss(d, N, 100)
	fmt.Printf("lookup_miss count: %d\n", missCount)

	remCount := benchRemove(N, 100)
	fmt.Printf("remove count: %d\n", remCount)

	iterSum := benchIterate(d, 1000)
	fmt.Printf("iterate sum: %d\n", iterSum)
}
