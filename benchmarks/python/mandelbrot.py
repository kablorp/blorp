import sys

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    limit_sq = 4.0
    max_iter = 50

    for y in range(n):
        row = []
        ci = 2.0 * y / n - 1.0
        for x in range(n):
            cr = 2.0 * x / n - 1.5
            zr = 0.0
            zi = 0.0
            inside = True
            for _ in range(max_iter):
                tr = zr * zr - zi * zi + cr
                ti = 2.0 * zr * zi + ci
                zr = tr
                zi = ti
                if zr * zr + zi * zi > limit_sq:
                    inside = False
                    break
            row.append('#' if inside else '.')
        print(''.join(row))

if __name__ == "__main__":
    main()
