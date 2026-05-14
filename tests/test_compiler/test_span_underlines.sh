#!/bin/bash
# Test that span underlines have correct widths

cd "$(dirname "$0")/../.."

BLORP="./blorp"
TMPFILE=$(mktemp /tmp/blorp_span_test_XXXXXX.brp)
trap "rm -f $TMPFILE" EXIT

total=0
passed=0
failed=0

check_underline() {
    local desc="$1"
    local input="$2"
    local expected_carets="$3"

    ((total++))

    echo "$input" > "$TMPFILE"
    local output
    output=$($BLORP check "$TMPFILE" 2>&1)

    # Count consecutive ^ characters in the output
    local caret_count
    caret_count=$(echo "$output" | grep -oE '\^+' | head -1 | wc -c)
    # wc -c includes trailing newline, subtract 1
    caret_count=$((caret_count - 1))

    if [ "$caret_count" -eq "$expected_carets" ]; then
        echo "  ok  $desc (width=$caret_count)"
        ((passed++))
    else
        echo "  FAIL $desc (expected width=$expected_carets, got=$caret_count)"
        echo "    Caret line: $(echo "$output" | grep '\^')"
        ((failed++))
    fi
}

echo "Span Underline Tests"
echo ""

# Identifier spans — undefined ident error uses the ident's span
check_underline "short identifier (4 chars)" \
    "func main(args: List[String]) -> Int:
    prnt" \
    4

check_underline "long identifier (21 chars)" \
    "func main(args: List[String]) -> Int:
    my_long_variable_name" \
    21

# Binary expression spans — type error uses the full binop span
check_underline "binary add Int+String (10 chars)" \
    "func main(args: List[String]) -> Int:
    42 + \"bad\"" \
    10

check_underline "binary mul Int*String (13 chars)" \
    "func main(args: List[String]) -> Int:
    100 * \"hello\"" \
    13

# Parse errors stay as point locs
check_underline "parse error is point loc" \
    "func main(args: List[String]) -> Int:
    if True
        0" \
    1

echo ""
if [ $failed -eq 0 ]; then
    echo "All $total span underline tests passed"
    exit 0
else
    echo "$passed/$total span underline tests passed ($failed failed)"
    exit 1
fi
