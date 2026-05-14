package main

import "fmt"

func main() {
	const SIZE = 1000
	const ITERATIONS = 10000

	// Allocate arrays
	arr1 := make([]int64, SIZE)
	arr2 := make([]int64, SIZE)

	// Initialize arrays
	for i := 0; i < SIZE; i++ {
		arr1[i] = int64(i)
		arr2[i] = int64(i * 2)
	}

	// Perform operations
	finalSum := int64(0)
	for iter := 0; iter < ITERATIONS; iter++ {
		// Element-wise add
		combined := make([]int64, SIZE)
		for i := 0; i < SIZE; i++ {
			combined[i] = arr1[i] + arr2[i]
		}

		// Element-wise multiply by scalar
		scaled := make([]int64, SIZE)
		for i := 0; i < SIZE; i++ {
			scaled[i] = combined[i] * 3
		}

		// Sum all elements
		sum := int64(0)
		for i := 0; i < SIZE; i++ {
			sum += scaled[i]
		}
		finalSum += sum
	}

	fmt.Printf("Completed %d iterations, final sum: %d\n", ITERATIONS, finalSum)
}
