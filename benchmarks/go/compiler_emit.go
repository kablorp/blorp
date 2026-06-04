package main

import (
	"fmt"
	"strings"
)

func emitStatement(builder *strings.Builder, functionID int, blockID int, statementID int) {
	target := (statementID + functionID + blockID) % 17
	left := (statementID*3 + functionID) % 23
	right := (blockID*5 + statementID) % 29
	fmt.Fprintf(builder, "  v%d = v%d + %d;\n", target, left, right)
}

func emitBlock(builder *strings.Builder, functionID int, blockID int, statements int) {
	fmt.Fprintf(builder, "block_%d:\n", blockID)
	for statementID := 0; statementID < statements; statementID++ {
		emitStatement(builder, functionID, blockID, statementID)
	}
	if blockID%3 == 0 {
		fmt.Fprintf(builder, "  goto block_%d;\n", blockID+1)
	} else {
		fmt.Fprintf(builder, "  acc += v%d;\n", blockID%17)
	}
}

func emitFunction(builder *strings.Builder, functionID int, blocks int, statements int) {
	fmt.Fprintf(builder, "static long f%d(long seed) {\n", functionID)
	builder.WriteString("  long acc = seed;\n")
	for i := 0; i < 24; i++ {
		fmt.Fprintf(builder, "  long v%d = seed + %d;\n", i, functionID+i)
	}
	for blockID := 0; blockID < blocks; blockID++ {
		emitBlock(builder, functionID, blockID, statements)
	}
	builder.WriteString("  return acc;\n}\n")
}

func emitProgram(functions int, blocks int, statements int) string {
	var builder strings.Builder
	builder.Grow(functions * blocks * statements * 24)
	builder.WriteString("/* generated benchmark program */\n")
	for functionID := 0; functionID < functions; functionID++ {
		emitFunction(&builder, functionID, blocks, statements)
	}
	return builder.String()
}

func checksumText(text string) int {
	checksum := 0
	for i := 0; i < len(text); i++ {
		checksum = checksum*33 + int(text[i])
	}
	return checksum
}

func main() {
	text := emitProgram(120, 10, 8)
	fmt.Printf("compiler_emit checksum: %d\n", checksumText(text))
	fmt.Printf("compiler_emit bytes: %d\n", len(text))
}
