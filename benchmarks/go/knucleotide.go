// The Computer Language Benchmarks Game
// https://benchmarksgame-team.pages.debian.net/benchmarksgame/
//
// K-nucleotide: count nucleotide frequencies

package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

const sampleDNA = "GGTATTTTAATTTATAGTGGTATTTTAATTTATAGT" +
	"ACGTACGTACGTACGTGGTATTTTAATTTATAGTAA" +
	"CGTGGTATTTTAATTTATAGTTGCAGGTATTTTAAT" +
	"TTATAGTACGGTATTACGTGGTATTTTAATTTATAG" +
	"TGGTATTTTAATTTATAGTTCGATCGATCGATCGAT" +
	"GGTAACGTACGTGGTATTTTAATTTATAGTTTTAAC" +
	"GGTATTTTAATTTATAGTAGCTAGCTAGCTAGCTAG" +
	"ACGTACGTGGTATTTTAATTTATAGTTGCATGCATG"

func generateSequence(n int) string {
	if n <= 0 {
		return ""
	}
	var buf strings.Builder
	buf.Grow(n)
	for buf.Len() < n {
		remaining := n - buf.Len()
		if remaining < len(sampleDNA) {
			buf.WriteString(sampleDNA[:remaining])
		} else {
			buf.WriteString(sampleDNA)
		}
	}
	return buf.String()
}

type KNuc struct {
	name  string
	count int
}

func countFrequencies(seq string, length int) (map[string]int, []string) {
	counts := make(map[string]int)
	order := make([]string, 0)
	for i := 0; i <= len(seq)-length; i++ {
		key := seq[i : i+length]
		if _, ok := counts[key]; !ok {
			order = append(order, key)
		}
		counts[key]++
	}
	return counts, order
}

func writeFrequencies(seq string, length int) {
	counts, order := countFrequencies(seq, length)

	// Preserve first-seen order for ties to match Blorp's stable sort.
	nucs := make([]KNuc, 0, len(order))
	total := 0
	for _, k := range order {
		v := counts[k]
		nucs = append(nucs, KNuc{k, v})
		total += v
	}
	sort.SliceStable(nucs, func(i, j int) bool {
		return nucs[i].count > nucs[j].count
	})

	for _, nuc := range nucs {
		fmt.Printf("%s %.3f\n", nuc.name, 100.0*float64(nuc.count)/float64(total))
	}
	fmt.Println()
}

func writeCount(seq string, fragment string) {
	counts, _ := countFrequencies(seq, len(fragment))
	fmt.Printf("%d\t%s\n", counts[fragment], fragment)
}

func main() {
	n := 100
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	seq := generateSequence(n)

	writeFrequencies(seq, 1)
	writeFrequencies(seq, 2)

	fragments := []string{"GGT", "GGTA", "GGTATT", "GGTATTTTAATT", "GGTATTTTAATTTATAGT"}
	for _, f := range fragments {
		writeCount(seq, f)
	}
}
