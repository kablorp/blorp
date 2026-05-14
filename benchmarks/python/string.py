ITERS = 100000

test_string = "The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes."
chain_string = "   The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes.   "

def bench_count(s, needle, iters):
    total = 0
    for _ in range(iters):
        total += s.count(needle)
    return total

def bench_contains(s, needle, iters):
    total = 0
    for _ in range(iters):
        if needle in s:
            total += 1
    return total

def bench_replace(s, old, new, iters):
    total = 0
    for _ in range(iters):
        result = s.replace(old, new)
        total += len(result)
    return total

def bench_substring(s, iters):
    total = 0
    for i in range(iters):
        start = i % 16
        result = s[start:start + 24]
        total += len(result)
    return total

def bench_split(s, delim, iters):
    total = 0
    for _ in range(iters):
        parts = s.split(delim)
        total += len(parts)
    return total

def bench_upper(s, iters):
    total = 0
    for _ in range(iters):
        result = s.upper()
        total += len(result)
    return total

def bench_lower(s, iters):
    total = 0
    for _ in range(iters):
        result = s.lower()
        total += len(result)
    return total

def bench_reverse(s, iters):
    total = 0
    for _ in range(iters):
        rev = s[::-1]
        total += len(rev)
    return total

def bench_trim(iters):
    padded = "   hello world   "
    total = 0
    for _ in range(iters):
        trimmed = padded.strip()
        total += len(trimmed)
    return total

def bench_chain_window_replace(s, iters):
    total = 0
    for i in range(iters):
        start = i % 16
        result = s.strip()[start:start + 40].replace(" ", "_")
        total += len(result)
    return total

def bench_chain_case_replace(s, iters):
    total = 0
    for _ in range(iters):
        result = s.lower().replace("the", "a").upper()
        total += len(result)
    return total

def bench_chain_trim_reverse(iters):
    padded = "   hello world   "
    total = 0
    for _ in range(iters):
        result = padded.strip()[::-1].replace("l", "L")
        total += len(result)
    return total

if __name__ == "__main__":
    print(f"count checksum: {bench_count(test_string, 'e', ITERS)}")
    print(f"contains checksum: {bench_contains(test_string, 'fox', ITERS)}")
    print(f"replace_same checksum: {bench_replace(test_string, 'the', 'THE', ITERS)}")
    print(f"replace_grow checksum: {bench_replace(test_string, 'dog', 'catapult', ITERS)}")
    print(f"replace_shrink checksum: {bench_replace(test_string, 'benchmarking', 'bench', ITERS)}")
    print(f"substring checksum: {bench_substring(test_string, ITERS)}")
    print(f"split checksum: {bench_split(test_string, ' ', ITERS)}")
    print(f"upper checksum: {bench_upper(test_string, ITERS)}")
    print(f"lower checksum: {bench_lower(test_string, ITERS)}")
    print(f"reverse checksum: {bench_reverse(test_string, ITERS)}")
    print(f"trim checksum: {bench_trim(ITERS)}")
    print(f"chain_window_replace checksum: {bench_chain_window_replace(chain_string, ITERS)}")
    print(f"chain_case_replace checksum: {bench_chain_case_replace(test_string, ITERS)}")
    print(f"chain_trim_reverse checksum: {bench_chain_trim_reverse(ITERS)}")
