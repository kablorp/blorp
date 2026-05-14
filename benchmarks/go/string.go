package main

import (
	"fmt"
	"strings"
)

const ITERS = 100000

var testString = "The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes."
var chainString = "   The quick brown fox jumps over the lazy dog. This is a test string for benchmarking purposes.   "

func benchCount(s, needle string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		total += strings.Count(s, needle)
	}
	return total
}

func benchContains(s, needle string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		if strings.Contains(s, needle) {
			total++
		}
	}
	return total
}

func benchReplace(s, old, newValue string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		result := strings.ReplaceAll(s, old, newValue)
		total += len(result)
	}
	return total
}

func benchSubstring(s string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		start := i % 16
		result := strings.Clone(s[start : start+24])
		total += len(result)
	}
	return total
}

func benchSplit(s, delim string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		parts := strings.Split(s, delim)
		total += len(parts)
	}
	return total
}

func benchToUpper(s string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		result := strings.ToUpper(s)
		total += len(result)
	}
	return total
}

func benchToLower(s string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		result := strings.ToLower(s)
		total += len(result)
	}
	return total
}

func benchReverse(s string, iters int) int {
	total := 0
	runes := []rune(s)
	for i := 0; i < iters; i++ {
		total += len(reverseRunes(runes))
	}
	return total
}

func reverseRunes(runes []rune) string {
	n := len(runes)
	rev := make([]rune, n)
	for j := 0; j < n; j++ {
		rev[j] = runes[n-1-j]
	}
	return string(rev)
}

func benchTrim(iters int) int {
	padded := "   hello world   "
	total := 0
	for i := 0; i < iters; i++ {
		trimmed := strings.Clone(strings.TrimSpace(padded))
		total += len(trimmed)
	}
	return total
}

func benchChainWindowReplace(s string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		start := i % 16
		trimmed := strings.TrimSpace(s)
		window := strings.Clone(trimmed[start : start+40])
		replaced := strings.ReplaceAll(window, " ", "_")
		total += len(replaced)
	}
	return total
}

func benchChainCaseReplace(s string, iters int) int {
	total := 0
	for i := 0; i < iters; i++ {
		result := strings.ToUpper(strings.ReplaceAll(strings.ToLower(s), "the", "a"))
		total += len(result)
	}
	return total
}

func benchChainTrimReverse(iters int) int {
	padded := "   hello world   "
	total := 0
	for i := 0; i < iters; i++ {
		trimmed := strings.Clone(strings.TrimSpace(padded))
		reversed := reverseRunes([]rune(trimmed))
		result := strings.ReplaceAll(reversed, "l", "L")
		total += len(result)
	}
	return total
}

func main() {
	fmt.Printf("count checksum: %d\n", benchCount(testString, "e", ITERS))
	fmt.Printf("contains checksum: %d\n", benchContains(testString, "fox", ITERS))
	fmt.Printf("replace_same checksum: %d\n", benchReplace(testString, "the", "THE", ITERS))
	fmt.Printf("replace_grow checksum: %d\n", benchReplace(testString, "dog", "catapult", ITERS))
	fmt.Printf("replace_shrink checksum: %d\n", benchReplace(testString, "benchmarking", "bench", ITERS))
	fmt.Printf("substring checksum: %d\n", benchSubstring(testString, ITERS))
	fmt.Printf("split checksum: %d\n", benchSplit(testString, " ", ITERS))
	fmt.Printf("upper checksum: %d\n", benchToUpper(testString, ITERS))
	fmt.Printf("lower checksum: %d\n", benchToLower(testString, ITERS))
	fmt.Printf("reverse checksum: %d\n", benchReverse(testString, ITERS))
	fmt.Printf("trim checksum: %d\n", benchTrim(ITERS))
	fmt.Printf("chain_window_replace checksum: %d\n", benchChainWindowReplace(chainString, ITERS))
	fmt.Printf("chain_case_replace checksum: %d\n", benchChainCaseReplace(testString, ITERS))
	fmt.Printf("chain_trim_reverse checksum: %d\n", benchChainTrimReverse(ITERS))
}
