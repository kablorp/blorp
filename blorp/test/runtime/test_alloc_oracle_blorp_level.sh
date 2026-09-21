#!/bin/bash
# Test: Blorp-level allocation oracle assertions (allocation-contract
# roadmap milestone 6). Each fixture is run in its OWN process with
# BLORP_ALLOCATOR_STATS=1 so it does not perturb the shared `bin/blorp
# test --suite` process other runtime tests run in (that flag changes
# get_mem_stats()'s bytes_allocated source, which several existing
# MemStats tests depend on being off).

BLORP=bin/blorp
SCALAR_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_scalar.brp
FOR_LOOP_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_for_loop.brp
MAP_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_map.brp
PASS=0
FAIL=0

echo "=== Allocation Oracle: Blorp-Level Tests ==="
echo ""

echo -n "Test 1: scalar arithmetic (a + b + c) shows zero heap deltas... "
scalar_output=$(BLORP_ALLOCATOR_STATS=1 $BLORP run "$SCALAR_FIXTURE" 2>&1 || true)
if grep -q "^PASS" <<< "$scalar_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  Got: $scalar_output"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 2: for-loop sum over List[Int] shows zero heap deltas... "
for_loop_output=$(BLORP_ALLOCATOR_STATS=1 $BLORP run "$FOR_LOOP_FIXTURE" 2>&1 || true)
if grep -q "^PASS" <<< "$for_loop_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (see docs/ALLOCATION_CONTRACT_ROADMAP.md: this is the case the"
    echo "  static analysis currently marks unknown because of the cooperative"
    echo "  checkpoint; a failure here is a genuine finding, not a test bug)"
    echo "  Got: $for_loop_output"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 3: xs.map(...) shows managed AND raw-buffer heap activity... "
map_output=$(BLORP_ALLOCATOR_STATS=1 $BLORP run "$MAP_FIXTURE" 2>&1 || true)
if grep -q "^PASS" <<< "$map_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  Got: $map_output"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Blorp-level allocation oracle results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
