#!/bin/bash
# Test: per-type leak report
#
# Verifies that BLORP_LEAK_CHECK produces type-aware leak reports.

BLORP=bin/blorp
FIXTURE=tests/fixtures/leak_string_deliberate.brp
SUITE_FIXTURE=tests/fixtures/leak_suite_deliberate.brp
PASS=0
FAIL=0

echo "=== Per-Type Leak Report Tests ==="
echo ""

# Test 1: Deliberate leak detected
echo -n "Test 1: deliberate leak is detected... "
output=$(BLORP_LEAK_CHECK=1 $BLORP run "$FIXTURE" 2>&1 || true)
if grep -q "leaked" <<< "$output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (no leak detected)"
    echo "  Got: $output"
    FAIL=$((FAIL + 1))
fi

# Test 2: Leak report includes a type/bucket label.
echo -n "Test 2: leak report shows type bucket... "
if grep -qiE "String|List|Channel|Closure|\\(unknown\\)" <<< "$output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (no type bucket in leak report)"
    echo "  Got: $(grep -i leak <<< "$output")"
    FAIL=$((FAIL + 1))
fi

# Test 3: Per-type counts shown
echo -n "Test 3: leak report shows per-type counts... "
if grep -qE "Leaked by type:" <<< "$output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (no per-type counts)"
    FAIL=$((FAIL + 1))
fi

# Test 4: Verbose mode shows per-object details (NEW FEATURE)
echo -n "Test 4: verbose mode shows individual leaked objects... "
verbose_output=$(BLORP_LEAK_CHECK=verbose $BLORP run "$FIXTURE" 2>&1 || true)
if grep -qE "Leaked object|leaked:.*String|  #[0-9]" <<< "$verbose_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (no per-object details in verbose mode)"
    echo "  Got: $(grep -i leak <<< "$verbose_output")"
    FAIL=$((FAIL + 1))
fi

# Test 5: Suite leak-check failure includes type/bucket details before reset.
echo -n "Test 5: suite leak failure shows type bucket... "
suite_output=$($BLORP test --leak-check --suite "$SUITE_FIXTURE" 2>&1 || true)
if grep -qE "\\[LEAK: [0-9]+ objects\\]" <<< "$suite_output" \
    && grep -qE "Leaked by type:" <<< "$suite_output" \
    && grep -qiE "String|List|Channel|Closure|\\(unknown\\)" <<< "$suite_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (no suite type bucket)"
    echo "  Got: $(grep -iE 'LEAK|Leaked by type|String|List|Channel|Closure|unknown' <<< "$suite_output")"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Diagnostic results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
