import sys
import math

def A(i, j):
    return 1.0 / ((i + j) * (i + j + 1) // 2 + i + 1)

def mul_Av(n, v):
    return [sum(A(i, j) * v[j] for j in range(n)) for i in range(n)]

def mul_Atv(n, v):
    return [sum(A(j, i) * v[j] for j in range(n)) for i in range(n)]

def mul_AtAv(n, v):
    u = mul_Av(n, v)
    return mul_Atv(n, u)

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
    u = [1.0] * n

    for _ in range(10):
        v = mul_AtAv(n, u)
        u = mul_AtAv(n, v)

    vBv = 0.0
    vv = 0.0
    for i in range(n):
        vBv += u[i] * v[i]
        vv += v[i] * v[i]

    print("%.9f" % math.sqrt(vBv / vv))

if __name__ == "__main__":
    main()
