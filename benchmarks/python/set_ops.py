"""Set Operations Benchmark for Python"""

def bench_build(n, iters):
    s = set()
    for _ in range(iters):
        s = set()
        for i in range(n):
            s.add(i)
    return s

def bench_contains_hit(s, n, iters):
    hits = 0
    for _ in range(iters):
        for i in range(n):
            if i in s:
                hits += 1
    return hits

def bench_contains_miss(s, n, iters):
    misses = 0
    for _ in range(iters):
        for i in range(n, n + n):
            if i not in s:
                misses += 1
    return misses

def bench_union(a, b, iters):
    checksum = 0
    for _ in range(iters):
        result = a | b
        checksum += len(result)
    return checksum

def bench_intersect(a, b, iters):
    checksum = 0
    for _ in range(iters):
        result = a & b
        checksum += len(result)
    return checksum

def bench_difference(a, b, iters):
    checksum = 0
    for _ in range(iters):
        result = a - b
        checksum += len(result)
    return checksum

if __name__ == "__main__":
    N = 10000
    s = bench_build(N, 200)
    print(f"build: done")
    hits = bench_contains_hit(s, N, 200)
    print(f"contains_hit: {hits}")
    misses = bench_contains_miss(s, N, 200)
    print(f"contains_miss: {misses}")
    a = set(range(5000))
    b = set(range(5000, 10000))
    union_count = bench_union(a, b, 500)
    print(f"union: {union_count}")
    c = set(range(N))
    half = N // 2
    d = set(range(half, half + N))
    intersect_count = bench_intersect(c, d, 500)
    print(f"intersect: {intersect_count}")
    diff_count = bench_difference(c, d, 500)
    print(f"difference: {diff_count}")
