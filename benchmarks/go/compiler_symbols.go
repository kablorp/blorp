package main

import "fmt"

type Scope struct {
	parent  int
	symbols map[string]int
}

func symbolName(scopeID int, slot int) string {
	return fmt.Sprintf("s%d_%d", scopeID, slot)
}

func makeScope(scopeID int, parent int, namesPerScope int) Scope {
	symbols := make(map[string]int, namesPerScope)
	for slot := 0; slot < namesPerScope; slot++ {
		symbols[symbolName(scopeID, slot)] = scopeID*1009 + slot
	}
	return Scope{parent: parent, symbols: symbols}
}

func buildScopes(count int, namesPerScope int) []Scope {
	scopes := make([]Scope, count)
	for scopeID := 0; scopeID < count; scopeID++ {
		scopes[scopeID] = makeScope(scopeID, scopeID-1, namesPerScope)
	}
	return scopes
}

func lookupSymbol(scopes []Scope, startScope int, name string) int {
	scopeID := startScope
	for scopeID >= 0 {
		if scopeID >= len(scopes) {
			return -1
		}
		scope := scopes[scopeID]
		if value, ok := scope.symbols[name]; ok {
			return value
		}
		scopeID = scope.parent
	}
	return -1
}

func runSymbolPass(scopes []Scope, scopeCount int, namesPerScope int, rounds int) int {
	checksum := 0
	for round := 0; round < rounds; round++ {
		for startScope := 0; startScope < scopeCount; startScope++ {
			localSlot := (startScope + round) % namesPerScope
			parentScope := 0
			if startScope > 12 {
				parentScope = startScope - 12
			}
			parentSlot := (round*7 + startScope) % namesPerScope
			missingSlot := namesPerScope + ((round + startScope) % namesPerScope)
			localName := symbolName(startScope, localSlot)
			parentName := symbolName(parentScope, parentSlot)
			missingName := symbolName(startScope+scopeCount+1, missingSlot)
			checksum += lookupSymbol(scopes, startScope, localName)
			checksum += lookupSymbol(scopes, startScope, parentName)
			checksum += lookupSymbol(scopes, startScope, missingName)
		}
	}
	return checksum
}

func main() {
	scopeCount := 220
	namesPerScope := 36
	scopes := buildScopes(scopeCount, namesPerScope)
	checksum := runSymbolPass(scopes, scopeCount, namesPerScope, 12)
	fmt.Printf("compiler_symbols checksum: %d\n", checksum)
}
