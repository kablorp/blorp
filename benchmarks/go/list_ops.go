package main

import (
	"cmp"
	"fmt"
	"slices"
)

func makeShuffled(n int) []int {
	list := make([]int, n)
	for i := 0; i < n; i++ {
		list[i] = (i*1103515245 + 12345) % n
	}
	return list
}

func benchAppend(n int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		list := make([]int, 0)
		for i := 0; i < n; i++ {
			list = append(list, i)
		}
		checksum += len(list)
	}
	return checksum
}

func benchSort(shuffled []int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		cpy := make([]int, len(shuffled))
		copy(cpy, shuffled)
		// Blorp List.sort is stable, so use Go's stable sorter for parity.
		slices.SortStableFunc(cpy, cmp.Compare[int])
		checksum += len(cpy) + cpy[0] + cpy[len(cpy)/2] + cpy[len(cpy)-1]
	}
	return checksum
}

func benchFilter(list []int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		evens := make([]int, 0)
		for _, x := range list {
			if x%2 == 0 {
				evens = append(evens, x)
			}
		}
		checksum += len(evens)
	}
	return checksum
}

func benchFold(list []int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		total := 0
		for _, x := range list {
			total += x
		}
		checksum += total
	}
	return checksum
}

func benchReverse(list []int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		rev := make([]int, len(list))
		n := len(list)
		for i := 0; i < n; i++ {
			rev[i] = list[n-1-i]
		}
		checksum += len(rev)
	}
	return checksum
}

func benchConcat(a []int, b []int, iters int) int {
	checksum := 0
	for iter := 0; iter < iters; iter++ {
		combined := make([]int, 0, len(a)+len(b))
		combined = append(combined, a...)
		combined = append(combined, b...)
		checksum += len(combined)
	}
	return checksum
}

func main() {
	const N = 10000

	appendCheck := benchAppend(N, 500)
	fmt.Printf("append checksum: %d\n", appendCheck)

	shuffled := makeShuffled(N)
	sortCheck := benchSort(shuffled, 200)
	fmt.Printf("sort checksum: %d\n", sortCheck)

	// Build a sequential list for filter/fold/reverse
	seq := make([]int, N)
	for i := 0; i < N; i++ {
		seq[i] = i
	}

	filterCheck := benchFilter(seq, 500)
	fmt.Printf("filter checksum: %d\n", filterCheck)

	foldCheck := benchFold(seq, 2000)
	fmt.Printf("fold checksum: %d\n", foldCheck)

	reverseCheck := benchReverse(seq, 1000)
	fmt.Printf("reverse checksum: %d\n", reverseCheck)

	// Split for concat benchmark
	half := N / 2
	a := seq[:half]
	b := seq[half:]

	concatCheck := benchConcat(a, b, 1000)
	fmt.Printf("concat checksum: %d\n", concatCheck)
}
