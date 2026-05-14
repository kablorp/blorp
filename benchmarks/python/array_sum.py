def main():
    SIZE = 1000
    ITERATIONS = 10000

    # Allocate array
    arr = list(range(SIZE))

    # Sum array many times
    total = 0
    for _ in range(ITERATIONS):
        subtotal = 0
        for value in arr:
            subtotal += value
        total += subtotal

    print(f"Completed {ITERATIONS} iterations, total: {total}")

if __name__ == "__main__":
    main()
