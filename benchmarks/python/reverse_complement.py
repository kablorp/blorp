import sys

LINE_WIDTH = 60

SEQUENCES = [
    (
        ">ONE Homo sapiens alu",
        "CTTGGCACCCGAGCAGCTCAAGGAGATGGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGATGCCACCACGCTGCCTGCC",
    ),
    (
        ">TWO IUB ambiguity codes",
        "ATGGCCAATGCCACTGCCGTCGTTTTACACAACGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGA",
    ),
    (
        ">THREE Homo sapiens frequency",
        "GCCACTGCCACCGGCAATCGCAAATGTGCCACTGCATCGTTTTACACNNNNNGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGAMRWSYKVHDBN",
    ),
]

COMPLEMENT = str.maketrans(
    "ATCGMKRYWSVBHDNatcgmkrywsvbhdn",
    "TAGCKMYRWSBVDHNtagckmyrwsbvdhn",
)

def reverse_complement(seq):
    return seq[::-1].translate(COMPLEMENT)

def print_wrapped(seq):
    pos = 0
    while pos < len(seq):
        print(seq[pos:pos + LINE_WIDTH])
        pos += LINE_WIDTH

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    total = 0
    for header, seq in SEQUENCES:
        full_seq = seq * n
        rc = reverse_complement(full_seq)
        total += len(rc)
        print(header)
        print_wrapped(rc)
    print(f"Total nucleotides: {total}")

if __name__ == "__main__":
    main()
