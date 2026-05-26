package main

import (
	"fmt"
	"os"
	"strconv"
	"sync"
	"time"
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

func main() {
	tasks := envInt("BENCH_SLEEP_TASKS", 512)
	sleepMS := envInt("BENCH_SLEEP_MS", 5)
	results := make([]int64, tasks)
	var wg sync.WaitGroup

	wg.Add(tasks)
	for id := 0; id < tasks; id++ {
		id := id
		go func() {
			defer wg.Done()
			time.Sleep(time.Duration(sleepMS) * time.Millisecond)
			results[id] = int64(id)
		}()
	}
	wg.Wait()

	var checksum int64
	for _, value := range results {
		checksum += value
	}
	fmt.Printf("checksum: %d\n", checksum)
}
