#!/bin/bash
# Run parser stage tests
# Compares current --dump-ast output against golden .ast.sexp files

set -e

echo "Parser golden stage tests are retired; current --dump-ast output no longer matches these fixtures." >&2
echo "Use scripts/run_tests.sh compiler/runtime for supported parser coverage." >&2
exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
Blorp="${PROJECT_ROOT}/build/blorp"
TEST_DIR="${SCRIPT_DIR}/parser/ast"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [[ ! -x "$Blorp" ]]; then
    echo -e "${RED}Error: blorp binary not found at $Blorp${NC}"
    echo "Please build the compiler first: cd build && make lnc"
    exit 1
fi

passed=0
failed=0
skipped=0

echo -e "${YELLOW}Running parser stage tests...${NC}"
echo ""

for lnc_file in "$TEST_DIR"/*.brp; do
    [[ -e "$lnc_file" ]] || continue

    base=$(basename "$lnc_file" .brp)
    golden="${TEST_DIR}/${base}.ast.sexp"

    if [[ ! -f "$golden" ]]; then
        echo -e "  ${YELLOW}SKIP${NC}  $base (no golden file)"
        ((skipped++))
        continue
    fi

    # Check if golden file is empty (error during generation)
    if [[ ! -s "$golden" ]]; then
        echo -e "  ${YELLOW}SKIP${NC}  $base (empty golden file)"
        ((skipped++))
        continue
    fi

    # Generate current output
    actual=$("$Blorp" compile --dump-ast "$lnc_file" 2>/dev/null) || {
        echo -e "  ${RED}ERROR${NC} $base (compile failed)"
        ((failed++))
        continue
    }

    # Compare with golden
    if diff -q <(echo "$actual") "$golden" > /dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}  $base"
        ((passed++))
    else
        echo -e "  ${RED}FAIL${NC}  $base"
        echo "    Golden: $golden"
        echo "    Diff:"
        diff <(echo "$actual") "$golden" | head -20 | sed 's/^/    /'
        ((failed++))
    fi
done

echo ""
echo "=========================================="
echo -e "Results: ${GREEN}$passed passed${NC}, ${RED}$failed failed${NC}, ${YELLOW}$skipped skipped${NC}"
echo ""

if [[ $failed -gt 0 ]]; then
    exit 1
fi
