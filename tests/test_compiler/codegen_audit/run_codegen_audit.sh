#!/bin/bash
# Codegen audit tests: compile .brp files and check generated C quality.
# Each test in should_pass/ must:
#   1. Compile without errors
#   2. The generated C must pass the warning sweep
#   3. Any EXPECT: comments must be satisfied

set -eu
BLORP="${1:-./blorp}"
PASS=0
FAIL=0
DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$DIR/../../.." && pwd -P)"
RUNTIME_DECL="$REPO_ROOT/compiler/lib/runtime_decl.c"
TEST_TIMEOUT="${BLORP_COMPILER_TEST_TIMEOUT:-${BLORP_TEST_TIMEOUT:-30}}"

case "$TEST_TIMEOUT" in
    ''|*[!0-9]*)
        echo "FAIL: invalid BLORP_COMPILER_TEST_TIMEOUT (must be a non-negative integer)"
        echo ""
        echo "Results: 0 passed, 1 failed"
        exit 1
        ;;
esac

if [ -n "${BLORP_CODEGEN_AUDIT_JOBS:-}" ]; then
    NJOBS="$BLORP_CODEGEN_AUDIT_JOBS"
elif [ -n "${BLORP_TEST_JOBS:-}" ]; then
    NJOBS="$BLORP_TEST_JOBS"
elif command -v sysctl >/dev/null 2>&1; then
    NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
elif command -v nproc >/dev/null 2>&1; then
    NJOBS=$(nproc 2>/dev/null || echo 4)
else
    NJOBS=4
fi

case "$NJOBS" in
    ''|*[!0-9]*)
        echo "FAIL: invalid BLORP_CODEGEN_AUDIT_JOBS/BLORP_TEST_JOBS (must be a positive integer)"
        echo ""
        echo "Results: 0 passed, 1 failed"
        exit 1
        ;;
    0)
        echo "FAIL: invalid BLORP_CODEGEN_AUDIT_JOBS/BLORP_TEST_JOBS (must be a positive integer)"
        echo ""
        echo "Results: 0 passed, 1 failed"
        exit 1
        ;;
esac

# The audit validates generated C syntax and frontend warnings only. Linking is
# covered by runtime tests and would make this suite pay avoidable linker cost.
CC_SYNTAX_ONLY_FLAGS=(-fsyntax-only)

if cc --version 2>/dev/null | grep -qi clang; then
    CC_WARNING_FLAGS=(
        "${CC_SYNTAX_ONLY_FLAGS[@]}"
        -Werror=unsequenced
        -Werror=incompatible-pointer-types
        -Wno-parentheses-equality
    )
else
    CC_WARNING_FLAGS=("${CC_SYNTAX_ONLY_FLAGS[@]}")
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

timeout_timer_pid=""

start_timeout_timer() {
    local watched_pid="$1"
    local timeout_file="$2"
    timeout_timer_pid=""

    if [ "$TEST_TIMEOUT" -le 0 ]; then
        return 0
    fi

    (
        sleep_pid=""
        trap 'if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM INT

        sleep "$TEST_TIMEOUT" &
        sleep_pid=$!
        wait "$sleep_pid" 2>/dev/null || exit 0

        if kill -0 "$watched_pid" 2>/dev/null; then
            : > "$timeout_file"
            terminate_process_tree "$watched_pid" TERM
            sleep 1
            terminate_process_tree "$watched_pid" KILL
        fi
    ) &
    timeout_timer_pid=$!
}

cancel_timeout_timer() {
    local timer_pid="$1"
    [ -n "$timer_pid" ] || return 0
    kill "$timer_pid" 2>/dev/null || true
    wait "$timer_pid" 2>/dev/null || true
}

run_with_timeout() {
    local output_file timeout_file pid timer_pid code
    output_file=$(mktemp "${TMPDIR:-/tmp}/blorp_codegen_audit.XXXXXX") || exit 1
    timeout_file=$(mktemp "${TMPDIR:-/tmp}/blorp_codegen_timeout.XXXXXX") || exit 1
    rm -f "$timeout_file"

    "$@" > "$output_file" 2>&1 &
    pid=$!
    start_timeout_timer "$pid" "$timeout_file"
    timer_pid="$timeout_timer_pid"

    wait "$pid"
    code=$?
    cancel_timeout_timer "$timer_pid"

    cat "$output_file"
    rm -f "$output_file"
    if [ -f "$timeout_file" ]; then
        rm -f "$timeout_file"
        return 124
    fi
    return "$code"
}

run_case() {
    local brp="$1"
    local test_name test_dir case_dir c_file compile_output compile_exit cc_output cc_exit
    local failed max_line_expect max_actual expect_c_lines expect_not_c_lines

    test_name="$(basename "$brp")"
    test_dir="$(cd "$(dirname "$brp")" && pwd -P)"
    case_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_codegen_case.XXXXXX") || {
        echo "FAIL: $test_name (could not create temp directory)"
        return 0
    }
    c_file="$case_dir/${test_name%.brp}.c"

    # Compile to C
    set +e
    compile_output=$(run_with_timeout "$BLORP" compile --no-format --no-embed-runtime -o "$c_file" "$brp")
    compile_exit=$?
    set -e
    if [ "$compile_exit" -eq 124 ]; then
        echo "FAIL: $test_name (blorp compile timed out after ${TEST_TIMEOUT}s)"
        rm -rf "$case_dir"
        return 0
    elif [ "$compile_exit" -ne 0 ]; then
        echo "FAIL: $test_name (blorp compile failed)"
        echo "$compile_output" | head -10 | sed 's/^/  /'
        rm -rf "$case_dir"
        return 0
    fi

    if [ ! -f "$c_file" ]; then
        echo "FAIL: $test_name (no .c generated)"
        rm -rf "$case_dir"
        return 0
    fi

    set +e
    cc_output=$(run_with_timeout cc "${CC_WARNING_FLAGS[@]}" -I "$test_dir" -include "$RUNTIME_DECL" "$c_file")
    cc_exit=$?
    set -e
    if [ "$cc_exit" -eq 124 ]; then
        echo "FAIL: $test_name (generated C warning sweep timed out after ${TEST_TIMEOUT}s)"
        rm -rf "$case_dir"
        return 0
    elif [ "$cc_exit" -ne 0 ]; then
        echo "FAIL: $test_name (generated C warning sweep failed)"
        echo "$cc_output" | head -20 | sed 's/^/  /'
        rm -rf "$case_dir"
        return 0
    fi

    # Check EXPECT comments
    failed=0

    # EXPECT: no line > N chars
    max_line_expect=$(grep -o 'EXPECT: no line > [0-9]* chars' "$brp" | grep -o '[0-9]*' || true)
    if [ -n "$max_line_expect" ]; then
        max_actual=$(awk '{ print length }' "$c_file" | sort -rn | head -1)
        if [ "$max_actual" -gt "$max_line_expect" ]; then
            echo "DETAIL: $test_name (max line $max_actual > $max_line_expect)"
            # Find which line
            awk -v limit="$max_line_expect" 'length > limit { printf "  line %d: %d chars\n", NR, length }' "$c_file" | head -3
            failed=1
        fi
    fi

    expect_c_lines=$(grep '^-- EXPECT-C:' "$brp" | sed 's/^-- EXPECT-C: *//' || true)
    while IFS= read -r expected; do
        [ -z "$expected" ] && continue
        if ! grep -qF -- "$expected" "$c_file"; then
            echo "DETAIL: $test_name (missing generated C: $expected)"
            failed=1
        fi
    done <<< "$expect_c_lines"

    expect_not_c_lines=$(grep '^-- EXPECT-NOT-C:' "$brp" | sed 's/^-- EXPECT-NOT-C: *//' || true)
    while IFS= read -r forbidden; do
        [ -z "$forbidden" ] && continue
        if grep -qF -- "$forbidden" "$c_file"; then
            echo "DETAIL: $test_name (forbidden generated C present: $forbidden)"
            failed=1
        fi
    done <<< "$expect_not_c_lines"

    rm -rf "$case_dir"

    if [ "$failed" -eq 0 ]; then
        echo "PASS: $test_name"
    else
        echo "FAIL: $test_name (generated C expectations failed)"
    fi
}

test_files=()
for brp in "$DIR"/should_pass/*.brp; do
    [ -f "$brp" ] && test_files+=("$brp")
done

if [ "${#test_files[@]}" -eq 0 ]; then
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

if [ "$NJOBS" -gt "${#test_files[@]}" ]; then
    NJOBS="${#test_files[@]}"
fi

stray_cases=()
for brp in "$DIR"/*.brp; do
    [ -f "$brp" ] && stray_cases+=("$brp")
done

if [ "${#stray_cases[@]}" -gt 0 ]; then
    echo "FAIL: codegen audit cases must live under should_pass/:"
    for brp in "${stray_cases[@]}"; do
        echo "  $(basename "$brp")"
    done
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

RESULT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/blorp_codegen_audit_results.XXXXXX") || exit 1
worker_pids=()

cleanup_results() {
    rm -rf "$RESULT_DIR"
}

terminate_workers() {
    local pid
    for pid in "${worker_pids[@]}"; do
        [ -n "$pid" ] && terminate_process_tree "$pid" TERM
    done
    sleep 1
    for pid in "${worker_pids[@]}"; do
        [ -n "$pid" ] && terminate_process_tree "$pid" KILL
    done
}

on_interrupt() {
    trap - INT TERM EXIT
    terminate_workers
    cleanup_results
    exit 130
}

trap on_interrupt INT TERM
trap cleanup_results EXIT

for worker in $(seq 0 $((NJOBS - 1))); do
    {
        idx=0
        for brp in "${test_files[@]}"; do
            if [ $((idx % NJOBS)) -eq "$worker" ]; then
                run_case "$brp"
            fi
            idx=$((idx + 1))
        done
    } > "$RESULT_DIR/worker_$worker" 2>&1 &
    worker_pids+=("$!")
done

for pid in "${worker_pids[@]}"; do
    if ! wait "$pid"; then
        echo "FAIL: codegen audit worker failed"
        FAIL=$((FAIL + 1))
    fi
done

for worker in $(seq 0 $((NJOBS - 1))); do
    while IFS= read -r line; do
        case "$line" in
            PASS:*)
                PASS=$((PASS + 1))
                ;;
            FAIL:*)
                FAIL=$((FAIL + 1))
                ;;
        esac
        echo "$line"
    done < "$RESULT_DIR/worker_$worker"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
