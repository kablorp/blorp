"""Pure numeric loop benchmark - Collatz sequence"""

def collatz_steps(start):
    n = start
    steps = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = n * 3 + 1
        steps += 1
    return steps

if __name__ == "__main__":
    total_steps = 0
    for i in range(1, 1000000):
        total_steps += collatz_steps(i)
    print(f"Total Collatz steps: {total_steps}")
