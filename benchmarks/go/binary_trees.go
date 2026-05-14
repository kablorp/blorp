// The Computer Language Benchmarks Game
// https://benchmarksgame-team.pages.debian.net/benchmarksgame/
//
// Binary trees: build and checksum complete binary trees

package main

import (
	"fmt"
	"os"
	"strconv"
)

type Node struct {
	value int64
	left  *Node
	right *Node
}

func bottomUpTreeWithValue(depth int, value int64) *Node {
	if depth <= 0 {
		return &Node{value: value}
	}
	next := value * 2
	return &Node{
		left:  bottomUpTreeWithValue(depth-1, next),
		right: bottomUpTreeWithValue(depth-1, next+1),
	}
}

func bottomUpTree(depth int) *Node {
	return bottomUpTreeWithValue(depth, 1)
}

func itemCheck(node *Node) int64 {
	if node.left == nil {
		return node.value
	}
	return 1 + itemCheck(node.left) + itemCheck(node.right)
}

func main() {
	n := 15
	if len(os.Args) > 1 {
		if v, err := strconv.Atoi(os.Args[1]); err == nil {
			n = v
		}
	}

	minDepth := 4
	maxDepth := n
	if minDepth+2 > n {
		maxDepth = minDepth + 2
	}

	stretchDepth := maxDepth + 1
	stretchTree := bottomUpTree(stretchDepth)
	fmt.Printf("stretch tree of depth %d\t check: %d\n", stretchDepth, itemCheck(stretchTree))

	longLivedTree := bottomUpTree(maxDepth)

	for depth := minDepth; depth <= maxDepth; depth += 2 {
		iterations := 1 << uint(maxDepth-depth+minDepth)
		check := int64(0)
		for i := 1; i <= iterations; i++ {
			t := bottomUpTree(depth)
			check += itemCheck(t)
		}
		fmt.Printf("%d\t trees of depth %d\t check: %d\n", iterations, depth, check)
	}

	fmt.Printf("long lived tree of depth %d\t check: %d\n", maxDepth, itemCheck(longLivedTree))
}
