package main

import "fmt"

func benchBuild(n int, iters int) map[int]struct{} {
	var s map[int]struct{}
	for iter := 0; iter < iters; iter++ {
		s = make(map[int]struct{})
		for i := 0; i < n; i++ {
			s[i] = struct{}{}
		}
	}
	return s
}

func benchContainsHit(s map[int]struct{}, n int, iters int) int {
	hits := 0
	for iter := 0; iter < iters; iter++ {
		for i := 0; i < n; i++ {
			if _, ok := s[i]; ok {
				hits++
			}
		}
	}
	return hits
}

func benchContainsMiss(s map[int]struct{}, n int, iters int) int {
	misses := 0
	for iter := 0; iter < iters; iter++ {
		for i := n; i < n+n; i++ {
			if _, ok := s[i]; !ok {
				misses++
			}
		}
	}
	return misses
}

func benchUnion(a map[int]struct{}, b map[int]struct{}, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		result := make(map[int]struct{})
		for k := range a {
			result[k] = struct{}{}
		}
		for k := range b {
			result[k] = struct{}{}
		}
		checksum += len(result)
	}
	return checksum
}

func benchIntersect(a map[int]struct{}, b map[int]struct{}, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		result := make(map[int]struct{})
		for k := range a {
			if _, ok := b[k]; ok {
				result[k] = struct{}{}
			}
		}
		checksum += len(result)
	}
	return checksum
}

func benchDifference(a map[int]struct{}, b map[int]struct{}, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		result := make(map[int]struct{})
		for k := range a {
			if _, ok := b[k]; !ok {
				result[k] = struct{}{}
			}
		}
		checksum += len(result)
	}
	return checksum
}

func main() {
	const N = 10000

	s := benchBuild(N, 200)
	fmt.Println("build: done")

	hits := benchContainsHit(s, N, 200)
	fmt.Printf("contains_hit: %d\n", hits)

	misses := benchContainsMiss(s, N, 200)
	fmt.Printf("contains_miss: %d\n", misses)

	// Build two 5k-element sets for union
	a := make(map[int]struct{})
	b := make(map[int]struct{})
	for i := 0; i < 5000; i++ {
		a[i] = struct{}{}
	}
	for i := 5000; i < 10000; i++ {
		b[i] = struct{}{}
	}

	unionCount := benchUnion(a, b, 500)
	fmt.Printf("union: %d\n", unionCount)

	// Build two overlapping 10k-element sets for intersect/difference
	c := make(map[int]struct{})
	d := make(map[int]struct{})
	for i := 0; i < N; i++ {
		c[i] = struct{}{}
	}
	half := N / 2
	for i := half; i < half+N; i++ {
		d[i] = struct{}{}
	}

	intersectCount := benchIntersect(c, d, 500)
	fmt.Printf("intersect: %d\n", intersectCount)

	diffCount := benchDifference(c, d, 500)
	fmt.Printf("difference: %d\n", diffCount)
}
