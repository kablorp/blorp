def main():
    SIZE = 1000
    ITERATIONS = 10000

    # Allocate arrays
    arr1 = list(range(SIZE))
    arr2 = [i * 2 for i in range(SIZE)]

    # Perform operations
    final_sum = 0
    for _ in range(ITERATIONS):
        # Element-wise add
        combined = [0] * SIZE
        for i in range(SIZE):
            combined[i] = arr1[i] + arr2[i]

        # Element-wise multiply by scalar
        scaled = [0] * SIZE
        for i in range(SIZE):
            scaled[i] = combined[i] * 3

        # Sum all elements
        subtotal = 0
        for value in scaled:
            subtotal += value
        final_sum += subtotal

    print(f"Completed {ITERATIONS} iterations, final sum: {final_sum}")

if __name__ == "__main__":
    main()
