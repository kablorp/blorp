#!/bin/bash
# Test: Blorp-level allocation oracle assertions (allocation-contract
# roadmap milestone 6). Each fixture is run in its OWN process with
# --memory-stats so it does not perturb the shared `bin/blorp
# test --suite` process other runtime tests run in (the flag turns the
# counters on for the whole process from its first allocation, which
# several existing MemStats tests depend on being off).

BLORP=bin/blorp
SCALAR_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_scalar.brp
FOR_LOOP_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_for_loop.brp
MAP_FIXTURE=blorp/test/runtime/fixture/alloc_oracle_map.brp
PROBE_FIXTURE=blorp/test/runtime/fixture/memory_stats_probe.brp
PASS=0
FAIL=0

echo "=== Allocation Oracle: Blorp-Level Tests ==="
echo ""

echo -n "Test 1: scalar arithmetic (a + b + c) shows zero heap deltas... "
scalar_output=$($BLORP run --memory-stats "$SCALAR_FIXTURE" 2>&1 || true)
if grep -q "^PASS" <<< "$scalar_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  Got: $scalar_output"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 2: for-loop sum over List[Int] shows zero heap deltas... "
for_loop_output=$($BLORP run --memory-stats "$FOR_LOOP_FIXTURE" 2>&1 || true)
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
map_output=$($BLORP run --memory-stats "$MAP_FIXTURE" 2>&1 || true)
if grep -q "^PASS" <<< "$map_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  Got: $map_output"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 4: --memory-stats builds a diagnostic child with counters on from the start... "
probe_on=$($BLORP run --memory-stats "$PROBE_FIXTURE" 2>&1 || true)
probe_off=$($BLORP run "$PROBE_FIXTURE" 2>&1 || true)
if grep -q "^counters_at_start=1 diagnostic_runtime=1" <<< "$probe_on" \
    && grep -q "^counters_at_start=0 diagnostic_runtime=0" <<< "$probe_off"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  with flag: $probe_on"
    echo "  without: $probe_off"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 5: the environment no longer selects memory stats for run... "
probe_env=$(BLORP_MEMORY_DIAGNOSTICS=1 $BLORP run "$PROBE_FIXTURE" 2>&1 || true)
if grep -q "^counters_at_start=0 diagnostic_runtime=0" <<< "$probe_env"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL"
    echo "  Got: $probe_env"
    FAIL=$((FAIL + 1))
fi

echo -n "Test 6: the retired --memory-diagnostics flag is rejected... "
retired_output=$($BLORP run --memory-diagnostics "$PROBE_FIXTURE" 2>&1)
retired_status=$?
if [ "$retired_status" -ne 0 ] && grep -q -- "--memory-diagnostics" <<< "$retired_output" \
    && grep -q -- "--memory-stats" <<< "$retired_output"; then
    echo "PASS"
    PASS=$((PASS + 1))
else
    echo "FAIL (status $retired_status)"
    echo "  Got: $retired_output"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Blorp-level allocation oracle results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
