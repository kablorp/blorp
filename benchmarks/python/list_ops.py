"""List Operations Benchmark for Python"""

def make_shuffled(n):
    return [(i * 1103515245 + 12345) % n for i in range(n)]

def bench_append(n, iters):
    checksum = 0
    for _ in range(iters):
        lst = []
        for i in range(n):
            lst.append(i)
        checksum += len(lst)
    return checksum

def bench_sort(shuffled, iters):
    checksum = 0
    for _ in range(iters):
        s = sorted(shuffled)
        checksum += len(s) + s[0] + s[len(s) // 2] + s[-1]
    return checksum

def bench_filter(lst, iters):
    checksum = 0
    for _ in range(iters):
        evens = [x for x in lst if x % 2 == 0]
        checksum += len(evens)
    return checksum

def bench_fold(lst, iters):
    checksum = 0
    for _ in range(iters):
        total = 0
        for x in lst:
            total += x
        checksum += total
    return checksum

def bench_reverse(lst, iters):
    checksum = 0
    for _ in range(iters):
        rev = lst[::-1]
        checksum += len(rev)
    return checksum

def bench_concat(a, b, iters):
    checksum = 0
    for _ in range(iters):
        combined = a + b
        checksum += len(combined)
    return checksum

if __name__ == "__main__":
    N = 10000
    append_check = bench_append(N, 500)
    print(f"append checksum: {append_check}")
    shuffled = make_shuffled(N)
    sort_check = bench_sort(shuffled, 200)
    print(f"sort checksum: {sort_check}")
    seq = list(range(N))
    filter_check = bench_filter(seq, 500)
    print(f"filter checksum: {filter_check}")
    fold_check = bench_fold(seq, 2000)
    print(f"fold checksum: {fold_check}")
    reverse_check = bench_reverse(seq, 1000)
    print(f"reverse checksum: {reverse_check}")
    half = N // 2
    a = list(range(half))
    b = list(range(half, N))
    concat_check = bench_concat(a, b, 1000)
    print(f"concat checksum: {concat_check}")
