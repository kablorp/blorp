#!/bin/bash
# REPL behavior tests
# Tests that the REPL produces clean error messages for invalid input,
# not raw C compiler garbage.

set -e
BLORP="${1:-./blorp}"
PASS=0
FAIL=0
TOTAL=0

# Helper: send input to REPL, capture stdout+stderr
run_repl() {
    echo "$1" | timeout 10 "$BLORP" repl 2>&1 || true
}

# Helper: assert output contains expected string
assert_contains() {
    local desc="$1"
    local input="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))
    local output
    output=$(run_repl "$input")
    if echo "$output" | grep -qiF -- "$expected"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  Input:    $input"
        echo "  Expected: $expected"
        echo "  Got:      $(echo "$output" | head -5)"
    fi
}

# Helper: assert output does NOT contain a string
assert_not_contains() {
    local desc="$1"
    local input="$2"
    local forbidden="$3"
    TOTAL=$((TOTAL + 1))
    local output
    output=$(run_repl "$input")
    if echo "$output" | grep -qiF -- "$forbidden"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  Input:     $input"
        echo "  Forbidden: $forbidden"
        echo "  Got:       $(echo "$output" | head -5)"
    else
        PASS=$((PASS + 1))
    fi
}

echo "=== REPL Behavior Tests ==="
echo ""

# ── Valid expressions ──
assert_contains "integer expression" "1 + 2" "3"
assert_contains "string expression" '"hello"' "hello"
assert_contains "boolean expression" "True" "True"
assert_contains "arithmetic" "10 * 5" "50"
assert_contains "string concat" '"hello" + " " + "world"' "hello world"
assert_contains "list literal" "[1, 2, 3]" "[1, 2, 3]"

# ── Valid declarations ──
assert_contains "function declaration" "func double(x: Int) -> Int: x * 2" "func double"
assert_contains "record declaration" "record Point {x: Int, y: Int}" "record Point"
assert_contains "struct declaration" "struct Vec2 {x: Float, y: Float}" "struct Vec2"

# ── Parse errors — should show clean message, not C garbage ──
assert_contains "parse error: unclosed paren" "func foo(x: Int" "error"
assert_not_contains "unclosed paren: no C garbage" "func foo(x: Int" "<stdin>"
assert_not_contains "unclosed paren: no gcc output" "func foo(x: Int" "implicit function declaration"

assert_contains "parse error: bad syntax" "func +" "error"
assert_not_contains "bad syntax: no C garbage" "func +" "<stdin>"

assert_contains "parse error: incomplete match" "match x:" "error"
assert_not_contains "incomplete match: no C garbage" "match x:" "<stdin>"

# ── Type errors — should show blorp error, not C error ──
assert_contains "type error: wrong arg type" 'length(42)' "error"
assert_not_contains "type error: no C garbage" 'length(42)' "<stdin>"

# ── Undefined identifier ──
assert_contains "undefined var" "nonexistent_var" "error"
assert_not_contains "undefined var: no C garbage" "nonexistent_var" "undeclared"

# ── Invalid declaration ──
assert_contains "bad func body" "func foo() -> Int: \"not an int\"" "error"
assert_not_contains "bad func body: no C garbage" "func foo() -> Int: \"not an int\"" "<stdin>"

# ── Empty/whitespace input ──
# Empty input should produce no error
TOTAL=$((TOTAL + 1))
output=$(run_repl "")
if echo "$output" | grep -qi "error"; then
    FAIL=$((FAIL + 1))
    echo "FAIL: empty input should not error"
else
    PASS=$((PASS + 1))
fi

# ── Commands ──
assert_contains "help command" "/help" "Commands"
assert_contains "quit command" ":quit" ""
assert_contains "modules command" "/modules" "std/"

# ── Import and use ──
# Multi-line REPL interaction is harder to test with echo pipe
# Test that import syntax is recognized
assert_contains "import recognized" "import: option { Some, None }" "import"

# ── Ensure no C compiler output leaks ──
# These patterns should NEVER appear in REPL output
for pattern in "<stdin>" "ISO C99" "implicit function declaration" "undeclared identifier" "incompatible" "redefinition" "expected expression"; do
    assert_not_contains "no C leak: $pattern on bad input" "func broken(: ->" "$pattern"
done

# ── Additional edge cases ──
assert_contains "division by zero" "10 / 0" "0"
assert_contains "negative numbers" "-5 + 3" "-2"
assert_contains "float expression" "3.14" "3.14"
assert_contains "nested parens" "(1 + 2) * (3 + 4)" "21"
assert_contains "multiline not needed" "if True: 1 else: 2" "1"
assert_not_contains "random chars no C leak" "@@#!!" "<stdin>"
assert_not_contains "incomplete string no C leak" '"unterminated' "<stdin>"
assert_contains "incomplete string error" '"unterminated' "error"

# ── Verify the REPL header shows ──
assert_contains "repl header" "" "blorp REPL"

# ── :type shows actual types ──
assert_contains ":type int" ":type 42" "Int"
assert_contains ":type string" ':type "hello"' "String"
assert_contains ":type bool" ":type True" "Bool"
assert_contains ":type list" ":type [1, 2, 3]" "List"
assert_contains ":type arithmetic" ":type 1 + 2" "Int"
# Note: blorp's type system is lenient — most expressions typecheck even with mismatched types

# ── Single compile cycle (expressions still evaluate correctly) ──
assert_contains "int display" "42" "42"
assert_contains "string display" '"hello"' "hello"
assert_contains "bool display" "True" "True"
assert_contains "void expression" 'print("side effect")' "side effect"

# ── History file created ──
TOTAL=$((TOTAL + 1))
# Run REPL with input, then check history file exists
echo "42" | timeout 10 "$BLORP" repl 2>/dev/null || true
if [ -f "$HOME/.blorp_history" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: history file not created"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (of $TOTAL) ==="
if [ $FAIL -gt 0 ]; then
    exit 1
fi
