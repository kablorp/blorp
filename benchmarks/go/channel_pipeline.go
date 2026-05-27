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

func main() {
	workers := envInt("BENCH_THREADS", 4)
	items := envInt("BENCH_ITEMS", 20000)
	rounds := envInt("BENCH_ROUNDS", 64)
	capacity := workers * 4
	input := make(chan int64, capacity)
	output := make(chan int64, capacity)

	go func() {
		for i := 0; i < items; i++ {
			input <- int64(i)
		}
		close(input)
	}()

	var wg sync.WaitGroup
	wg.Add(workers)
	for workerID := 0; workerID < workers; workerID++ {
		go func() {
			defer wg.Done()
			for value := range input {
				output <- heavyWork(value, rounds)
			}
		}()
	}

	var checksum int64
	for received := 0; received < items; received++ {
		checksum += <-output
	}
	wg.Wait()

	fmt.Printf("checksum: %d\n", checksum)
	fmt.Printf("processed: %d\n", items)
}
