package main

import "fmt"

func main() {
	const SIZE = 1000
	const ITERATIONS = 10000

	// Allocate array
	arr := make([]int64, SIZE)

	// Initialize array
	for i := 0; i < SIZE; i++ {
		arr[i] = int64(i)
	}

	// Sum array many times
	total := int64(0)
	for iter := 0; iter < ITERATIONS; iter++ {
		sum := int64(0)
		for i := 0; i < SIZE; i++ {
			sum += arr[i]
		}
		total += sum
	}

	fmt.Printf("Completed %d iterations, total: %d\n", ITERATIONS, total)
}
