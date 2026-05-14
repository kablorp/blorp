// Reverse complement benchmark over shared fixed FASTA input.

package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

const lineWidth = 60

var sequences = []struct {
	header string
	seq    string
}{
	{
		">ONE Homo sapiens alu",
		"CTTGGCACCCGAGCAGCTCAAGGAGATGGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGATGCCACCACGCTGCCTGCC",
	},
	{
		">TWO IUB ambiguity codes",
		"ATGGCCAATGCCACTGCCGTCGTTTTACACAACGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGA",
	},
	{
		">THREE Homo sapiens frequency",
		"GCCACTGCCACCGGCAATCGCAAATGTGCCACTGCATCGTTTTACACNNNNNGTTTGCCACCACGCTGCCTGCCGCTGACCTCCTGGCGAAGCTGACCTCCTGGCGAAGCTGAAGATGCCACCACGCTGCCTGCCGCTGAMRWSYKVHDBN",
	},
}

var complement [256]byte

func init() {
	for i := range complement {
		complement[i] = byte(i)
	}
	pairs := [][2]byte{
		{'A', 'T'}, {'T', 'A'},
		{'C', 'G'}, {'G', 'C'},
		{'M', 'K'}, {'K', 'M'},
		{'R', 'Y'}, {'Y', 'R'},
		{'W', 'W'}, {'S', 'S'},
		{'V', 'B'}, {'B', 'V'},
		{'H', 'D'}, {'D', 'H'},
		{'N', 'N'},
		{'a', 't'}, {'t', 'a'},
		{'c', 'g'}, {'g', 'c'},
		{'m', 'k'}, {'k', 'm'},
		{'r', 'y'}, {'y', 'r'},
		{'w', 'w'}, {'s', 's'},
		{'v', 'b'}, {'b', 'v'},
		{'h', 'd'}, {'d', 'h'},
		{'n', 'n'},
	}
	for _, pair := range pairs {
		complement[pair[0]] = pair[1]
	}
}

func reverseComplement(seq string) string {
	n := len(seq)
	result := make([]byte, n)
	for i := 0; i < n; i++ {
		result[i] = complement[seq[n-1-i]]
	}
	return string(result)
}

func printWrapped(seq string) {
	for i := 0; i < len(seq); i += lineWidth {
		end := i + lineWidth
		if end > len(seq) {
			end = len(seq)
		}
		fmt.Println(seq[i:end])
	}
}

func main() {
	n := 1
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	total := 0
	for _, entry := range sequences {
		fullSeq := strings.Repeat(entry.seq, n)
		rc := reverseComplement(fullSeq)
		total += len(rc)
		fmt.Println(entry.header)
		printWrapped(rc)
	}
	fmt.Printf("Total nucleotides: %d\n", total)
}
