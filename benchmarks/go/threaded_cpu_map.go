package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
)

func envInt(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

func heavyWork(seed int64, rounds int) int64 {
	acc := seed + 1
	for i := 0; i < rounds; i++ {
		acc = (acc*1103515245 + 12345 + int64(i) + seed) % 2147483647
	}
	return acc % 1000003
}

func workerSum(workerID int, workers int, items int, rounds int) int64 {
	var checksum int64
	for i := workerID; i < items; i += workers {
		checksum += heavyWork(int64(i), rounds)
	}
	return checksum
}

func main() {
	workers := envInt("BENCH_THREADS", 4)
	items := envInt("BENCH_ITEMS", 10000)
	rounds := envInt("BENCH_ROUNDS", 1000)
	results := make([]int64, workers)
	var wg sync.WaitGroup

	wg.Add(workers)
	for workerID := 0; workerID < workers; workerID++ {
		workerID := workerID
		go func() {
			defer wg.Done()
			results[workerID] = workerSum(workerID, workers, items, rounds)
		}()
	}
	wg.Wait()

	var checksum int64
	for _, value := range results {
		checksum += value
	}
	fmt.Printf("checksum: %d\n", checksum)
}
