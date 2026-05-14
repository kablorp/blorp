import sys

def fannkuch(n):
    perm = list(range(n))
    perm1 = list(range(n))
    count = list(range(1, n + 1))
    maxflips = 0
    checksum = 0
    nperm = 0

    while True:
        # Count flips for current perm1
        if perm1[0]:
            perm[:] = perm1[:]
            flips = 0
            first = perm[0]
            while first:
                new_first = perm[first]
                # Reverse perm[0..first]
                lo = 0
                hi = first
                while lo < hi:
                    perm[lo], perm[hi] = perm[hi], perm[lo]
                    lo += 1
                    hi -= 1
                perm[first] = first
                first = new_first
                flips += 1
            if flips > maxflips:
                maxflips = flips
            if nperm & 1 == 0:
                checksum += flips
            else:
                checksum -= flips

        nperm += 1

        # Generate next permutation
        # Rotate the first two elements
        first = perm1[1]
        perm1[1] = perm1[0]
        perm1[0] = first

        i = 1
        count[i] -= 1
        while count[i] <= 0:
            count[i] = i + 1
            i += 1
            if i >= n:
                print("%d\nPfannkuchen(%d) = %d" % (checksum, n, maxflips))
                return
            # Rotate perm1[0..i+1] left by one
            new_first = perm1[0]
            for j in range(i):
                perm1[j] = perm1[j + 1]
            perm1[i] = new_first
            count[i] -= 1

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    fannkuch(n)

if __name__ == "__main__":
    main()
