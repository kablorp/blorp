import sys
from collections import defaultdict

SAMPLE_DNA = (
    "GGTATTTTAATTTATAGTGGTATTTTAATTTATAGT"
    "ACGTACGTACGTACGTGGTATTTTAATTTATAGTAA"
    "CGTGGTATTTTAATTTATAGTTGCAGGTATTTTAAT"
    "TTATAGTACGGTATTACGTGGTATTTTAATTTATAG"
    "TGGTATTTTAATTTATAGTTCGATCGATCGATCGAT"
    "GGTAACGTACGTGGTATTTTAATTTATAGTTTTAAC"
    "GGTATTTTAATTTATAGTAGCTAGCTAGCTAGCTAG"
    "ACGTACGTGGTATTTTAATTTATAGTTGCATGCATG"
)

def generate_sequence(n):
    if n <= 0:
        return ""
    copies = n // len(SAMPLE_DNA) + 1
    return (SAMPLE_DNA * copies)[:n]

def count_frequencies(seq, frame):
    counts = defaultdict(int)
    length = len(seq)
    for i in range(length - frame + 1):
        key = seq[i:i + frame]
        counts[key] += 1
    return counts

def print_frequencies(seq, frame):
    counts = count_frequencies(seq, frame)
    total = sum(counts.values())
    items = sorted(counts.items(), key=lambda x: -x[1])
    for key, count in items:
        print("%s %.3f" % (key, 100.0 * count / total))
    print()

def print_count(seq, fragment):
    counts = count_frequencies(seq, len(fragment))
    print("%d\t%s" % (counts.get(fragment, 0), fragment))

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    seq = generate_sequence(n)

    for frame in (1, 2):
        print_frequencies(seq, frame)

    for fragment in ("GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"):
        print_count(seq, fragment)

if __name__ == "__main__":
    main()
