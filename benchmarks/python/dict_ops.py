"""Dict Operations Benchmark for Python"""

def bench_build(n, iters):
    d = {}
    for _ in range(iters):
        d = {}
        for i in range(n):
            d[i] = i * 7
    return d

def bench_lookup_hit(d, n, iters):
    checksum = 0
    for _ in range(iters):
        for i in range(n):
            v = d.get(i)
            if v is not None:
                checksum += v
    return checksum

def bench_lookup_miss(d, n, iters):
    misses = 0
    for _ in range(iters):
        for i in range(n, n + n):
            if d.get(i) is None:
                misses += 1
    return misses

def bench_remove(n, iters):
    removed = 0
    for _ in range(iters):
        d = {}
        for i in range(n):
            d[i] = i * 7
        for i in range(n):
            del d[i]
            removed += 1
    return removed

def bench_iterate(d, iters):
    total = 0
    for _ in range(iters):
        for k, v in d.items():
            total += v
    return total

if __name__ == "__main__":
    N = 10000
    d = bench_build(N, 100)
    print(f"build: done")
    hit_sum = bench_lookup_hit(d, N, 100)
    print(f"lookup_hit checksum: {hit_sum}")
    miss_count = bench_lookup_miss(d, N, 100)
    print(f"lookup_miss count: {miss_count}")
    rem_count = bench_remove(N, 100)
    print(f"remove count: {rem_count}")
    iter_sum = bench_iterate(d, 1000)
    print(f"iterate sum: {iter_sum}")
