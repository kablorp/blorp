#!/bin/bash
# Run blorp test suites
#
# Usage:
#   scripts/run_tests.sh                    # Run all tests
#   scripts/run_tests.sh unit               # OCaml unit tests only
#   scripts/run_tests.sh compiler           # Compiler tests plus codegen audit
#   scripts/run_tests.sh runtime            # C runtime smoke + runtime .brp tests
#   scripts/run_tests.sh leak               # Focused --leak-check ownership baselines
#   scripts/run_tests.sh doctest            # Doctests only (std/ library)
#   scripts/run_tests.sh cli                # Public CLI smoke and exit-code checks
#   scripts/run_tests.sh unit compiler      # Multiple suites
#   scripts/run_tests.sh --coverage         # Unit tests with coverage report

cd "$(dirname "$0")/.."

# Parse arguments
suites=()
coverage=false
for arg in "$@"; do
    case "$arg" in
        --coverage) coverage=true ;;
        unit|compiler|runtime|leak|doctest|cli) suites+=("$arg") ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [unit] [compiler] [runtime] [leak] [doctest] [cli] [--coverage]"
            exit 1
            ;;
    esac
done

# Default: run all suites
if [ ${#suites[@]} -eq 0 ]; then
    suites=(unit compiler runtime leak doctest cli)
fi

test_timeout="${BLORP_TEST_TIMEOUT:-30}"
runtime_roots=()
for root in tests/test_blorp/ tests/test_std/ tests/test_pkg/; do
    if [ -d "$root" ]; then
        runtime_roots+=("$root")
    fi
done

# Background process tracking. Bash does not give us structured child cleanup,
# so keep this small and explicit: track the real worker PIDs and recursively
# terminate their descendants on interruption.
suite_pids=()
suite_names=()
suite_tmpdir=""
dune_tmpdir=""

if [ -z "${DUNE_BUILD_DIR:-}" ]; then
    mkdir -p compiler/_build
    dune_tmpdir=$(mktemp -d "$PWD/compiler/_build/isolated.XXXXXX") || exit 1
    export DUNE_BUILD_DIR="$dune_tmpdir"
fi

list_child_pids() {
    local parent="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$parent" 2>/dev/null || true
    else
        ps -o pid= -P "$parent" 2>/dev/null | tr -d ' ' || true
    fi
}

terminate_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child
    [ -n "$pid" ] || return 0

    for child in $(list_child_pids "$pid"); do
        terminate_process_tree "$child" "$signal"
    done
    kill -"$signal" "$pid" 2>/dev/null || true
}

wait_for_tracked_pids() {
    local pid
    for pid in "$@"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
}

cleanup_suite_tmpdir() {
    if [ -n "$suite_tmpdir" ]; then
        rm -rf "$suite_tmpdir"
        suite_tmpdir=""
    fi
}

cleanup_tmpdirs() {
    cleanup_suite_tmpdir
    if [ -n "$dune_tmpdir" ]; then
        rm -rf "$dune_tmpdir"
        dune_tmpdir=""
    fi
}

terminate_parallel_suites() {
    local pid
    if [ ${#suite_pids[@]} -gt 0 ]; then
        for pid in "${suite_pids[@]}"; do
            terminate_process_tree "$pid" TERM
        done
        sleep 1
        for pid in "${suite_pids[@]}"; do
            terminate_process_tree "$pid" KILL
        done
        wait_for_tracked_pids "${suite_pids[@]}"
        suite_pids=()
        suite_names=()
    fi
}

on_interrupt() {
    echo "" >&2
    echo "Interrupted; terminating test suites..." >&2
    trap - INT TERM EXIT
    terminate_parallel_suites
    cleanup_tmpdirs
    exit 130
}

trap on_interrupt INT TERM
trap cleanup_tmpdirs EXIT

# Ensure compiler is built. If the rebuild fails, stop here; continuing with a
# stale ./blorp is worse than not running tests because it can hide strict
# typecheck failures behind old compiler behavior.
if ! make --quiet 2>/dev/null; then
    if ! make; then
        echo "Error: compiler build failed; aborting test run." >&2
        exit 1
    fi
fi

# ─── Result tracking (bash 3.2 compatible) ──────────────────────────
# Each suite gets: _status, _passed, _failed, _tests, _failures (newline-separated list)
unit_status="SKIP"; unit_passed=0; unit_failed=0; unit_tests=0; unit_failures=""
compiler_status="SKIP"; compiler_passed=0; compiler_failed=0; compiler_tests=0; compiler_failures=""
runtime_status="SKIP"; runtime_passed=0; runtime_failed=0; runtime_tests=0; runtime_failures=""
leak_status="SKIP"; leak_passed=0; leak_failed=0; leak_tests=0; leak_failures=""
doctest_status="SKIP"; doctest_passed=0; doctest_failed=0; doctest_tests=0; doctest_failures=""
cli_status="SKIP"; cli_passed=0; cli_failed=0; cli_tests=0; cli_failures=""

# ─── Parsers ────────────────────────────────────────────────────────

parse_unit() {
    local output="$1"
    # Alcotest:
    #   "Test Successful in 0.014s. 71 tests run."
    #   "6 failures! in 3.666s. 734 tests run."
    local tests_line failures_line tests failures
    tests_line=$(echo "$output" | grep -o '[0-9][0-9]* tests run' | tail -1)
    failures_line=$(echo "$output" | grep -o '[0-9][0-9]* failures!' | tail -1)
    tests=0
    failures=0

    if [ -n "$tests_line" ]; then
        tests="${tests_line%% *}"
    fi
    if [ -n "$failures_line" ]; then
        failures="${failures_line%% *}"
    fi

    if [ "$tests" -eq 0 ] && [ "$failures" -eq 0 ]; then
        unit_tests=1
        unit_failed=1
        unit_passed=0
    else
        unit_tests=$tests
        unit_failed=$failures
        unit_passed=$((tests - failures))
    fi
    if [ "$failures" -eq 0 ] && [ "$tests" -gt 0 ]; then
        unit_status="PASS"
    else
        unit_status="FAIL"
        unit_failures=$(echo "$output" | grep '^\> \[FAIL\]' | sed 's/^> \[FAIL\][[:space:]]*//')
    fi
}

parse_compiler() {
    local output="$1"
    # "✓ All 500 compiler tests passed" or "✗ 490/500 compiler tests passed (10 failed)"
    local summary
    summary=$(echo "$output" | grep -E '(All [0-9]+ compiler|[0-9]+/[0-9]+ compiler)')
    if echo "$summary" | grep -q "All"; then
        local n
        n=$(echo "$summary" | grep -o 'All [0-9]*' | grep -o '[0-9]*')
        compiler_passed=$n
        compiler_tests=$n
        compiler_status="PASS"
    elif [ -n "$summary" ]; then
        compiler_passed=$(echo "$summary" | grep -o '[0-9]*/[0-9]*' | cut -d/ -f1)
        compiler_tests=$(echo "$summary" | grep -o '[0-9]*/[0-9]*' | cut -d/ -f2)
        compiler_failed=$(echo "$summary" | grep -o '([0-9]* failed)' | grep -o '[0-9]*')
        compiler_status="FAIL"
        compiler_failures=$(echo "$output" | grep -E '^(FAIL:|✗ \[)' | sed -e 's/^FAIL: *//' -e 's/^✗ //')
    else
        compiler_status="FAIL"
        compiler_passed=0
        compiler_failed=1
        compiler_tests=1
        compiler_failures="compiler suite exited before reporting a summary"
    fi
}

parse_blorp_output() {
    local output="$1"
    local key="$2"
    # "Results: 403 passed, 3 failed (3312 tests)" or "Results: 45 passed, 0 failed (0 tests, 718 doctests)"
    local summary
    summary=$(echo "$output" | grep '^Results:')
    if [ -z "$summary" ]; then
        eval "${key}_status=FAIL"
        eval "${key}_passed=0"
        eval "${key}_failed=1"
        eval "${key}_tests=1"
        local fails
        fails=$(echo "$output" | grep -E '^(FAIL:|Combined test compile failed|error:|\(C compilation failed\))' | head -1)
        [ -n "$fails" ] || fails="$key suite exited before reporting Results"
        eval "${key}_failures=\$fails"
        return
    fi

    local p f t
    p=$(echo "$summary" | grep -o '[0-9]* passed' | grep -o '[0-9]*')
    f=$(echo "$summary" | grep -o '[0-9]* failed' | grep -o '[0-9]*')
    # Total: sum all numbers inside parentheses (handles "0 tests, 718 doctests")
    t=$(echo "$summary" | sed 's/.*(\(.*\))/\1/' | grep -o '[0-9]*' | awk '{s+=$1} END {print s}')

    eval "${key}_passed=$p"
    eval "${key}_failed=$f"
    eval "${key}_tests=$t"
    if [ "$f" -eq 0 ]; then
        eval "${key}_status=PASS"
    else
        eval "${key}_status=FAIL"
        local fails
        fails=$(echo "$output" | grep "^FAIL:" | sed 's/^FAIL: *//')
        eval "${key}_failures=\$fails"
    fi
}

parse_cli() {
    local output="$1"
    local summary p f t
    summary=$(echo "$output" | grep '^Results:')
    if [ -z "$summary" ]; then
        cli_status="FAIL"
        cli_passed=0
        cli_failed=1
        cli_tests=1
        cli_failures="cli suite exited before reporting Results"
        return
    fi

    p=$(echo "$summary" | grep -o '[0-9]* passed' | grep -o '[0-9]*')
    f=$(echo "$summary" | grep -o '[0-9]* failed' | grep -o '[0-9]*')
    t=$(echo "$summary" | sed 's/.*(\(.*\))/\1/' | grep -o '[0-9]*' | head -1)

    cli_passed=$p
    cli_failed=$f
    cli_tests=$t
    if [ "$f" -eq 0 ]; then
        cli_status="PASS"
    else
        cli_status="FAIL"
        cli_failures=$(echo "$output" | grep '^FAIL:' | sed 's/^FAIL: *//')
    fi
}

capture_stream() {
    local output_file="$1"
    shift
    "$@" 2>&1 | tee "$output_file"
    return ${PIPESTATUS[0]}
}

run_std_typecheck_preflight() {
    echo "═══ Std Typecheck Preflight ═══"
    echo ""

    local checked output_file
    checked=$(find std -name '*.brp' | wc -l | tr -d ' ')
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_std_typecheck.XXXXXX") || exit 1

    if ! {
        ./blorp check --no-format std
    } > "$output_file" 2>&1; then
        echo "FAIL: std typecheck preflight"
        sed -n '1,80p' "$output_file"
        rm -f "$output_file"
        return 1
    fi

    rm -f "$output_file"
    echo "Std typecheck preflight passed ($checked modules)."
    echo ""
    return 0
}

needs_std_typecheck_preflight=false
for suite in "${suites[@]}"; do
    case "$suite" in
        compiler|runtime|leak|doctest)
            needs_std_typecheck_preflight=true
            ;;
    esac
done

if $needs_std_typecheck_preflight; then
    run_std_typecheck_preflight || exit 1
fi

# ─── Suite runners ──────────────────────────────────────────────────

run_unit() {
    echo "═══ Unit Tests (OCaml) ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_unit.XXXXXX") || exit 1
    if $coverage; then
        capture_stream "$output_file" make coverage
        exit_code=$?
    else
        (cd compiler && dune runtest --force) 2>&1 | tee "$output_file"
        exit_code=${PIPESTATUS[0]}
    fi
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    if [ $exit_code -eq 0 ]; then
        parse_unit "$output"
    else
        unit_status="FAIL"
        parse_unit "$output"
        unit_status="FAIL"
    fi
    return $exit_code
}

run_compiler() {
    echo "═══ Compiler Tests (should_pass/should_fail + codegen audit) ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_compiler.XXXXXX") || exit 1
    capture_stream "$output_file" tests/test_compiler/run_compiler_tests.sh
    exit_code=$?
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    parse_compiler "$output"
    return $exit_code
}

run_runtime() {
    echo "═══ Runtime Tests (C smoke + .brp) ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_runtime.XXXXXX") || exit 1
    {
        scripts/runtime_c_smoke.sh && ./blorp test --timeout "$test_timeout" "${runtime_roots[@]}"
    } 2>&1 | tee "$output_file"
    exit_code=${PIPESTATUS[0]}
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    parse_blorp_output "$output" "runtime"
    return $exit_code
}

run_leak() {
    echo "═══ Leak-Check Baselines (.brp) ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_leak.XXXXXX") || exit 1
    capture_stream "$output_file" ./blorp test --leak-check --suite --timeout "$test_timeout" tests/test_blorp/memory/leak_check_baselines/
    exit_code=$?
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    parse_blorp_output "$output" "leak"
    return $exit_code
}

run_doctest() {
    echo "═══ Doctests (std/) ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_doctest.XXXXXX") || exit 1
    capture_stream "$output_file" ./blorp test --doc --timeout "$test_timeout" std/
    exit_code=$?
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    parse_blorp_output "$output" "doctest"
    return $exit_code
}

run_cli() {
    echo "═══ CLI Smoke / Exit Codes ═══"
    echo ""
    local output exit_code output_file
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_cli.XXXXXX") || exit 1
    capture_stream "$output_file" env BLORP_CLI_TEST_TIMEOUT="${BLORP_CLI_TEST_TIMEOUT:-$test_timeout}" tests/test_cli.sh
    exit_code=$?
    output=$(cat "$output_file")
    rm -f "$output_file"
    echo ""
    parse_cli "$output"
    return $exit_code
}

# ─── Run suites ─────────────────────────────────────────────────────

any_failed=false

# Keep suite execution serial. The individual compiler/runtime runners already
# parallelize internally where they can do so safely; overlapping top-level
# suites makes failures harder to attribute and can starve short CLI/runtime
# timeout checks under load.
for suite in "${suites[@]}"; do
    case "$suite" in
        unit)     run_unit     || any_failed=true ;;
        compiler) run_compiler || any_failed=true ;;
        runtime)  run_runtime  || any_failed=true ;;
        leak)     run_leak     || any_failed=true ;;
        doctest)  run_doctest  || any_failed=true ;;
        cli)      run_cli      || any_failed=true ;;
    esac
done

# ─── Summary ────────────────────────────────────────────────────────

total_tests=0
total_passed=0
total_failed=0
overall="PASS"

for s in "${suites[@]}"; do
    st=$(eval echo "\$${s}_status")
    p=$(eval echo "\$${s}_passed")
    f=$(eval echo "\$${s}_failed")
    t=$(eval echo "\$${s}_tests")
    total_passed=$((total_passed + p))
    total_failed=$((total_failed + f))
    total_tests=$((total_tests + t))
    if [ "$st" = "FAIL" ]; then
        overall="FAIL"
    fi
done

echo "════════════════════════════════════════════════"
echo "  Suite         Status   Passed  Failed   Tests"
echo "────────────────────────────────────────────────"
for s in "${suites[@]}"; do
    st=$(eval echo "\$${s}_status")
    p=$(eval echo "\$${s}_passed")
    f=$(eval echo "\$${s}_failed")
    t=$(eval echo "\$${s}_tests")
    case "$s" in
        unit)     label="Unit" ;;
        compiler) label="Compiler" ;;
        runtime)  label="Runtime" ;;
        leak)     label="Leak-check" ;;
        doctest)  label="Doctests" ;;
        cli)      label="CLI" ;;
    esac
    printf "  %-13s %-6s %8d %7d %7d\n" "$label" "$st" "$p" "$f" "$t"
done
echo "────────────────────────────────────────────────"
printf "  %-13s %-6s %8d %7d %7d\n" "Total" "$overall" "$total_passed" "$total_failed" "$total_tests"
echo "════════════════════════════════════════════════"

# List failing tests if any
if [ "$overall" = "FAIL" ]; then
    echo ""
    echo "Failed tests:"
    for s in "${suites[@]}"; do
        local_failures=$(eval echo "\"\$${s}_failures\"")
        if [ -n "$local_failures" ]; then
            echo "$local_failures" | while IFS= read -r line; do
                echo "  $line"
            done
        fi
    done
fi

if $any_failed; then
    exit 1
fi
