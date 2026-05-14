package main

import "fmt"

func collatzSteps(start int) int {
	n := start
	steps := 0
	for n != 1 {
		if n%2 == 0 {
			n = n / 2
		} else {
			n = n*3 + 1
		}
		steps++
	}
	return steps
}

func main() {
	totalSteps := 0
	for i := 1; i < 1000000; i++ {
		totalSteps += collatzSteps(i)
	}
	fmt.Printf("Total Collatz steps: %d\n", totalSteps)
}
