#!/bin/bash
# Generate golden files for stage tests
#
# Usage: ./generate_golden.sh [stage]
#   stage: lexer, parser, typecheck, all (default: all)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
Blorp="${PROJECT_ROOT}/build/blorp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if blorp binary exists
if [[ ! -x "$Blorp" ]]; then
    echo -e "${RED}Error: blorp binary not found at $Blorp${NC}"
    echo "Please build the compiler first: cd build && make lnc"
    exit 1
fi

generate_lexer_goldens() {
    echo -e "${YELLOW}Generating lexer golden files...${NC}"
    local dir="${SCRIPT_DIR}/lexer/tokens"
    local count=0

    for lnc_file in "$dir"/*.brp; do
        [[ -e "$lnc_file" ]] || continue
        local base=$(basename "$lnc_file" .brp)
        local golden="${dir}/${base}.tokens.json"

        echo "  $base.brp -> $base.tokens.json"
        "$Blorp" compile --dump-tokens "$lnc_file" > "$golden" 2>/dev/null || {
            echo -e "${RED}    Error generating golden for $base${NC}"
            continue
        }
        ((count++))
    done

    echo -e "${GREEN}Generated $count lexer golden files${NC}"
}

generate_parser_goldens() {
    echo -e "${YELLOW}Generating parser golden files...${NC}"
    local dir="${SCRIPT_DIR}/parser/ast"
    local count=0

    for lnc_file in "$dir"/*.brp; do
        [[ -e "$lnc_file" ]] || continue
        local base=$(basename "$lnc_file" .brp)
        local golden="${dir}/${base}.ast.sexp"

        echo "  $base.brp -> $base.ast.sexp"
        "$Blorp" compile --dump-ast "$lnc_file" > "$golden" 2>/dev/null || {
            echo -e "${RED}    Error generating golden for $base${NC}"
            continue
        }
        ((count++))
    done

    echo -e "${GREEN}Generated $count parser golden files${NC}"
}

generate_typecheck_goldens() {
    echo -e "${YELLOW}Generating typecheck golden files...${NC}"
    local dir="${SCRIPT_DIR}/typecheck/typed_ast"
    local count=0

    for lnc_file in "$dir"/*.brp; do
        [[ -e "$lnc_file" ]] || continue
        local base=$(basename "$lnc_file" .brp)
        local golden="${dir}/${base}.typed.sexp"

        echo "  $base.brp -> $base.typed.sexp"
        "$Blorp" compile --dump-typed-ast "$lnc_file" > "$golden" 2>/dev/null || {
            echo -e "${RED}    Error generating golden for $base${NC}"
            continue
        }
        ((count++))
    done

    echo -e "${GREEN}Generated $count typecheck golden files${NC}"
}

# Parse arguments
STAGE="${1:-all}"

case "$STAGE" in
    lexer)
        generate_lexer_goldens
        ;;
    parser)
        generate_parser_goldens
        ;;
    typecheck)
        generate_typecheck_goldens
        ;;
    all)
        generate_lexer_goldens
        echo ""
        generate_parser_goldens
        echo ""
        generate_typecheck_goldens
        ;;
    *)
        echo "Usage: $0 [stage]"
        echo "  stage: lexer, parser, typecheck, all (default: all)"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"
