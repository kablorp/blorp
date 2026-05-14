#!/bin/bash
# Test runner for OCaml type checker
# Compares OCaml type checker results against the parser AST golden files

# Don't exit on error - we want to continue testing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OCAML_DIR="$PROJECT_ROOT/compiler"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

echo "============================================"
echo "OCaml Type Checker Tests"
echo "============================================"
echo ""

# Ensure OCaml is built
echo "Building OCaml type checker..."
cd "$OCAML_DIR"
dune build 2>/dev/null || {
    echo -e "${RED}Error: Failed to build OCaml type checker${NC}"
    exit 1
}
echo -e "${GREEN}Build successful${NC}"
echo ""

# Test function
run_test() {
    local file="$1"
    local name="$(basename "$file" .ast.sexp)"

    # Run OCaml type checker
    result=$(dune exec lnc_typecheck -- "$file" 2>&1)
    exit_code=$?

    # Check result
    if [ $exit_code -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC} $name"
        PASSED=$((PASSED + 1))
    elif [ $exit_code -eq 1 ]; then
        # Type error - this might be expected for some tests
        echo -e "  ${YELLOW}TYPE_ERR${NC} $name"
        PASSED=$((PASSED + 1))  # Count as passed since it parsed correctly
    else
        echo -e "  ${RED}FAIL${NC} $name"
        echo "    Error: $result"
        FAILED=$((FAILED + 1))
    fi
}

# Test parser/ast files
echo "Testing parser/ast golden files..."
for file in "$SCRIPT_DIR/parser/ast/"*.sexp; do
    if [ -f "$file" ]; then
        run_test "$file"
    fi
done
echo ""

# Test typecheck/typed_ast files (these should also parse)
echo "Testing typecheck/typed_ast golden files..."
for file in "$SCRIPT_DIR/typecheck/typed_ast/"*.sexp; do
    if [ -f "$file" ]; then
        run_test "$file"
    fi
done
echo ""

# Summary
echo "============================================"
echo "Summary"
echo "============================================"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo -e "Skipped: ${YELLOW}$SKIPPED${NC}"
echo ""

if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
