#!/bin/bash
# Runner for compiler tests (should_pass/should_fail tests plus codegen audit)
# Tests in should_pass/ directories must compile without errors
# Tests in should_fail/ directories must fail compilation
#
# Error message verification:
#   should_fail tests can include "-- EXPECT: <diagnostic line>" annotations to
#   verify the compiler produces the correct error message, not just a nonzero
#   exit code.
#   - Case-sensitive exact-line match against normalized diagnostic lines
#   - Use "-- EXPECT-CONTAINS: <substring>" only for deliberate full-output checks
#   - Multiple EXPECT / EXPECT-CONTAINS lines require ALL to match (AND)
#   - No EXPECT lines → exit-code-only check (backward compatible)
#   - Do not include file paths, line numbers, or source underline output
#
# Parallelism: tests are split into N chunks (one per CPU core) and run
# concurrently in background subshells. Each chunk writes results to a
# temp file; the parent collects and prints them in order.

cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd -P)

verbose=false
self_test_timeout=false
while [ $# -gt 0 ]; do
    case "$1" in
        --verbose)
            verbose=true
            ;;
        --quiet)
            verbose=false
            ;;
        --self-test-timeout)
            self_test_timeout=true
            ;;
        -h|--help)
            echo "Usage: tests/test_compiler/run_compiler_tests.sh [--quiet|--verbose] [--self-test-timeout]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: tests/test_compiler/run_compiler_tests.sh [--quiet|--verbose] [--self-test-timeout]" >&2
            exit 1
            ;;
    esac
    shift
done

# Find the compiler binary
if [ -n "${BLORP_BIN:-}" ]; then
    BLORP_BIN="$BLORP_BIN"
elif [ -f "$REPO_ROOT/blorp" ]; then
    BLORP_BIN="$REPO_ROOT/blorp"
else
    echo "Error: blorp compiler not found. Run 'make' first."
    exit 1
fi

# Detect parallelism
if [ -n "$BLORP_TEST_JOBS" ]; then
    NJOBS="$BLORP_TEST_JOBS"
elif command -v sysctl >/dev/null 2>&1; then
    NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
elif command -v nproc >/dev/null 2>&1; then
    NJOBS=$(nproc 2>/dev/null || echo 4)
else
    NJOBS=4
fi

compiler_test_timeout="${BLORP_COMPILER_TEST_TIMEOUT:-${BLORP_TEST_TIMEOUT:-30}}"
case "$compiler_test_timeout" in
    ''|*[!0-9]*)
        echo "Error: BLORP_COMPILER_TEST_TIMEOUT must be a non-negative integer." >&2
        exit 1
        ;;
esac

if ! $self_test_timeout && [ "${BLORP_COMPILER_TEST_RUNNER:-in-process}" != "legacy" ]; then
    runner_args=(__compiler-tests --blorp-bin "$BLORP_BIN" --timeout "$compiler_test_timeout")
    if $verbose; then
        runner_args+=(--verbose)
    else
        runner_args+=(--quiet)
    fi
    exec "$BLORP_BIN" "${runner_args[@]}"
fi

if [ "$compiler_test_timeout" -eq 0 ]; then
    echo "Compiler Tests (${NJOBS} workers, timeout disabled)"
else
    echo "Compiler Tests (${NJOBS} workers, ${compiler_test_timeout}s timeout)"
fi
echo ""

# Create temp directory for per-chunk result files
RESULT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/blorp_compiler_tests.XXXXXX")
pids=()
codegen_pid=""

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

    if [ "$compiler_test_timeout" -le 0 ]; then
        return 0
    fi

    (
        sleep_pid=""
        trap 'if [ -n "$sleep_pid" ]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM INT

        sleep "$compiler_test_timeout" &
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

run_command_capture() {
    local output_file timeout_file pid timer_pid code
    output_file=$(mktemp "$RESULT_DIR/cmd.XXXXXX") || exit 1
    timeout_file=$(mktemp "$RESULT_DIR/timeout.XXXXXX") || exit 1
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

run_blorp_capture() {
    run_command_capture "$BLORP_BIN" "$@"
}

normalized_diagnostic_lines() {
    local test="$1"
    awk -v test="$test" '
        index($0, test ": ") == 1 {
            print substr($0, length(test) + 3)
            next
        }
        /^error: / || /^warning: / {
            print
            next
        }
        /^[[:space:]]*(expected|found): / {
            sub(/^[[:space:]]*/, "")
            print
            next
        }
        /^[[:space:]]*= help: / {
            sub(/^[[:space:]]*= /, "")
            print
            next
        }
        /^[[:space:]]*= note: / {
            sub(/^[[:space:]]*= /, "")
            print
            next
        }
    '
}

check_error_expectations() {
    local test="$1"
    local output="$2"
    local suite="$3"
    local testname="$4"
    local mismatch_detail="$5"
    local diagnostics expect_failed fail_lines line expected

    diagnostics=$(printf '%s\n' "$output" | normalized_diagnostic_lines "$test")
    expect_failed=0
    fail_lines=""

    while IFS= read -r line; do
        expected="${line#*-- EXPECT: }"
        [ -z "$expected" ] && continue
        if ! printf '%s\n' "$diagnostics" | grep -Fx -- "$expected" >/dev/null; then
            if [ $expect_failed -eq 0 ]; then
                fail_lines="DETAIL   $mismatch_detail"$'\n'
            fi
            fail_lines+="DETAIL   Missing exact diagnostic line: \"$expected\""$'\n'
            expect_failed=1
        fi
    done < <(grep '^-- EXPECT: ' "$test" || true)

    while IFS= read -r line; do
        expected="${line#*-- EXPECT-CONTAINS: }"
        [ -z "$expected" ] && continue
        if ! printf '%s\n' "$output" | grep -qF -- "$expected"; then
            if [ $expect_failed -eq 0 ]; then
                fail_lines="DETAIL   $mismatch_detail"$'\n'
            fi
            fail_lines+="DETAIL   Missing output substring: \"$expected\""$'\n'
            expect_failed=1
        fi
    done < <(grep '^-- EXPECT-CONTAINS: ' "$test" || true)

    if [ $expect_failed -eq 1 ]; then
        echo "FAIL ✗ [$suite] $testname"
        printf "%s" "$fail_lines"
        echo "DETAIL   Normalized diagnostic lines:"
        if [ -n "$diagnostics" ]; then
            printf '%s\n' "$diagnostics" | sed 's/^/DETAIL     /'
        else
            echo "DETAIL     (none)"
        fi
        echo "DETAIL   Actual output:"
        printf '%s\n' "$output" | head -10 | sed 's/^/DETAIL     /'
        return 1
    fi

    return 0
}

wait_for_tracked_pids() {
    local pid
    for pid in "$@"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
}

terminate_background_work() {
    local tracked=()
    local pid

    for pid in "${pids[@]}"; do
        [ -n "$pid" ] && tracked+=("$pid")
    done
    [ -n "$codegen_pid" ] && tracked+=("$codegen_pid")

    if [ ${#tracked[@]} -gt 0 ]; then
        for pid in "${tracked[@]}"; do
            terminate_process_tree "$pid" TERM
        done
        sleep 1
        for pid in "${tracked[@]}"; do
            terminate_process_tree "$pid" KILL
        done
        wait_for_tracked_pids "${tracked[@]}"
    fi

    pids=()
    codegen_pid=""
}

cleanup_result_dir() {
    [ -n "$RESULT_DIR" ] && rm -rf "$RESULT_DIR"
}

on_interrupt() {
    echo "" >&2
    echo "Interrupted; terminating compiler test workers..." >&2
    trap - INT TERM EXIT
    terminate_background_work
    cleanup_result_dir
    exit 130
}

trap on_interrupt INT TERM
trap cleanup_result_dir EXIT

if $self_test_timeout; then
    self_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_compiler_timeout.XXXXXX")
    self_test_child_pid="$self_test_dir/child.pid"
    self_test_fake="$self_test_dir/fake-blorp"
    cat > "$self_test_fake" <<'EOF'
#!/bin/sh
sleep 30 &
echo $! > "$BLORP_COMPILER_TIMEOUT_CHILD_PID"
wait
EOF
    chmod +x "$self_test_fake"

    BLORP_BIN="$self_test_fake"
    compiler_test_timeout=1
    BLORP_COMPILER_TIMEOUT_CHILD_PID="$self_test_child_pid"
    export BLORP_COMPILER_TIMEOUT_CHILD_PID
    self_test_output=$(run_blorp_capture check fake.brp)
    self_test_code=$?

    if [ "$self_test_code" -ne 124 ]; then
        echo "FAIL: expected timeout exit 124, got $self_test_code"
        echo "$self_test_output"
        rm -rf "$self_test_dir"
        exit 1
    fi

    child_pid=$(cat "$self_test_child_pid" 2>/dev/null || true)
    if [ -n "$child_pid" ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$child_pid" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        if kill -0 "$child_pid" 2>/dev/null; then
            kill -KILL "$child_pid" 2>/dev/null || true
            echo "FAIL: timeout did not kill descendant process $child_pid"
            rm -rf "$self_test_dir"
            exit 1
        fi
    fi

    rm -rf "$self_test_dir"
    echo "PASS: compiler runner timeout self-test"
    exit 0
fi

# ─── Collect all test files ──────────────────────────────────────

test_files=()

for category in parser typecheck infer; do
    dir="tests/test_compiler/$category"
    [ -d "$dir/should_pass" ] && for f in "$dir/should_pass"/*.brp; do [ -f "$f" ] && test_files+=("$f"); done
    [ -d "$dir/should_fail" ] && for f in "$dir/should_fail"/*.brp; do [ -f "$f" ] && test_files+=("$f"); done
done

for sub in format/should_pass format/should_fail format/should_error purify/should_purify purify/should_not_purify purify/should_rewrite; do
    dir="tests/test_compiler/$sub"
    [ -d "$dir" ] && for f in "$dir"/*.brp; do [ -f "$f" ] && test_files+=("$f"); done
done

# Round-trip tests: format idempotency for all should_pass parser tests
for f in tests/test_compiler/parser/should_pass/*.brp; do
    [ -f "$f" ] && test_files+=("roundtrip:$f")
done

total=${#test_files[@]}

prewarm_formatter_renderer() {
    local warmup_dir warmup_file output exit_code saved_timeout warmup_timeout
    warmup_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_formatter_warmup.XXXXXX") || exit 1
    warmup_file="$warmup_dir/warmup.brp"

    printf 'func main(args: List[String]) -> Int:\n\t0\n' > "$warmup_file"

    saved_timeout="$compiler_test_timeout"
    warmup_timeout="$compiler_test_timeout"
    if [ "$compiler_test_timeout" -gt 0 ] && [ "$compiler_test_timeout" -lt 120 ]; then
        compiler_test_timeout=120
        warmup_timeout=120
    fi

    output=$(run_blorp_capture format --check "$warmup_file")
    exit_code=$?
    compiler_test_timeout="$saved_timeout"
    rm -rf "$warmup_dir"

    if [ $exit_code -eq 124 ]; then
        echo "FAIL: formatter renderer warmup timed out after ${warmup_timeout}s" >&2
        return 1
    elif [ $exit_code -ne 0 ]; then
        echo "FAIL: formatter renderer warmup failed" >&2
        echo "$output" | head -10 | sed 's/^/  /' >&2
        return 1
    fi
}

if ! prewarm_formatter_renderer; then
    cleanup_result_dir
    exit 1
fi

# ─── Test runner (runs a list of tests sequentially) ───────────

run_test() {
    local test="$1"
    local testname=$(basename "$test")
    local parent_dir=$(basename "$(dirname "$test")")
    local grandparent=$(basename "$(dirname "$(dirname "$test")")")

    # Round-trip format idempotency test
    if [[ "$test" == roundtrip:* ]]; then
        local real_file="${test#roundtrip:}"
        local testname=$(basename "$real_file")
        local tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_rt.XXXXXX")
        cp "$real_file" "$tmpdir/pass1.brp"
        fmt1_output=$(run_blorp_capture format "$tmpdir/pass1.brp")
        local fmt1=$?
        cp "$tmpdir/pass1.brp" "$tmpdir/pass2.brp"
        fmt2_output=$(run_blorp_capture format "$tmpdir/pass2.brp")
        local fmt2=$?
        if [ $fmt1 -eq 124 ]; then
            echo "FAIL ✗ [roundtrip] $testname"
            echo "DETAIL   Format timed out on first pass after ${compiler_test_timeout}s"
        elif [ $fmt1 -ne 0 ]; then
            echo "FAIL ✗ [roundtrip] $testname"
            echo "DETAIL   Format failed on first pass"
            echo "$fmt1_output" | head -5 | sed 's/^/DETAIL     /'
        elif [ $fmt2 -eq 124 ]; then
            echo "FAIL ✗ [roundtrip] $testname"
            echo "DETAIL   Format timed out on second pass after ${compiler_test_timeout}s"
        elif [ $fmt2 -ne 0 ]; then
            echo "FAIL ✗ [roundtrip] $testname"
            echo "DETAIL   Format failed on second pass (formatted output not parseable)"
            echo "$fmt2_output" | head -5 | sed 's/^/DETAIL     /'
        elif ! diff -q "$tmpdir/pass1.brp" "$tmpdir/pass2.brp" > /dev/null 2>&1; then
            echo "FAIL ✗ [roundtrip] $testname"
            echo "DETAIL   Formatter is not idempotent"
            diff "$tmpdir/pass1.brp" "$tmpdir/pass2.brp" | head -5 | sed 's/^/DETAIL     /'
        else
            echo "PASS ✓ [roundtrip] $testname"
        fi
        rm -rf "$tmpdir"
        return
    fi

    if [ "$grandparent" = "format" ]; then
        output=$(run_blorp_capture format --check "$test")
        exit_code=$?
        if [ "$parent_dir" = "should_pass" ]; then
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [format/should_pass] $testname"
                echo "DETAIL   Format check timed out after ${compiler_test_timeout}s"
            elif [ $exit_code -eq 0 ]; then
                echo "PASS ✓ [format/should_pass] $testname"
            else
                echo "FAIL ✗ [format/should_pass] $testname"
                echo "DETAIL   Expected: already formatted"
                echo "DETAIL   Got: needs formatting"
            fi
        elif [ "$parent_dir" = "should_fail" ]; then
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [format/should_fail] $testname"
                echo "DETAIL   Format check timed out after ${compiler_test_timeout}s"
            elif [ $exit_code -ne 0 ]; then
                echo "PASS ✓ [format/should_fail] $testname"
            else
                echo "FAIL ✗ [format/should_fail] $testname"
                echo "DETAIL   Expected: needs formatting"
                echo "DETAIL   Got: already formatted"
            fi
        elif [ "$parent_dir" = "should_error" ]; then
            # Formatter must reject with error (non-zero exit + EXPECT match)
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [format/should_error] $testname"
                echo "DETAIL   Format check timed out after ${compiler_test_timeout}s"
            elif [ $exit_code -eq 0 ]; then
                echo "FAIL ✗ [format/should_error] $testname"
                echo "DETAIL   Expected: formatter error"
                echo "DETAIL   Got: format succeeded"
            else
                if check_error_expectations \
                    "$test" "$output" "format/should_error" "$testname" \
                    "Formatter rejected, but error message mismatch:"; then
                    echo "PASS ✓ [format/should_error] $testname"
                fi
            fi
        fi

    elif [ "$grandparent" = "purify" ]; then
        if [ "$parent_dir" = "should_rewrite" ]; then
            tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-purify-test.XXXXXX")
            tmpfile="$tmpdir/$testname"
            cp "$test" "$tmpfile"
            output=$(run_blorp_capture purify "$tmpfile")
            exit_code=$?
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [purify/should_rewrite] $testname"
                echo "DETAIL   Purify timed out after ${compiler_test_timeout}s"
                rm -rf "$tmpdir"
                return
            elif [ $exit_code -ne 0 ]; then
                echo "FAIL ✗ [purify/should_rewrite] $testname"
                echo "DETAIL   Purify failed"
                echo "$output" | sed 's/^/DETAIL     /'
                rm -rf "$tmpdir"
                return
            fi

            check_output=$(run_blorp_capture check --no-format "$tmpfile")
            check_exit=$?
            if [ $check_exit -ne 0 ]; then
                echo "FAIL ✗ [purify/should_rewrite] $testname"
                echo "DETAIL   Rewritten file did not typecheck"
                echo "$check_output" | sed 's/^/DETAIL     /'
                rm -rf "$tmpdir"
                return
            fi

            body=$(grep -v '^-- EXPECT-' "$tmpfile" || true)
            all_match=true
            expect_contains=$(grep '^-- EXPECT-CONTAINS:' "$test" | sed 's/^-- EXPECT-CONTAINS: *//' || true)
            while IFS= read -r expect; do
                [ -z "$expect" ] && continue
                if ! echo "$body" | grep -qF -- "$expect"; then
                    all_match=false
                    echo "FAIL ✗ [purify/should_rewrite] $testname"
                    echo "DETAIL   Missing rewritten text: $expect"
                    break
                fi
            done <<< "$expect_contains"
            if $all_match; then
                expect_absent=$(grep '^-- EXPECT-NOT-CONTAINS:' "$test" | sed 's/^-- EXPECT-NOT-CONTAINS: *//' || true)
                while IFS= read -r expect; do
                    [ -z "$expect" ] && continue
                    if echo "$body" | grep -qF -- "$expect"; then
                        all_match=false
                        echo "FAIL ✗ [purify/should_rewrite] $testname"
                        echo "DETAIL   Forbidden rewritten text present: $expect"
                        break
                    fi
                done <<< "$expect_absent"
            fi
            if $all_match; then
                echo "PASS ✓ [purify/should_rewrite] $testname"
            fi
            rm -rf "$tmpdir"
        else
            output=$(run_blorp_capture purify --dry-run "$test")
            exit_code=$?
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [purify/$parent_dir] $testname"
                echo "DETAIL   Purify timed out after ${compiler_test_timeout}s"
                return
            fi
            if [ "$parent_dir" = "should_purify" ]; then
                if [ -n "$output" ]; then
                    echo "PASS ✓ [purify/should_purify] $testname"
                else
                    echo "FAIL ✗ [purify/should_purify] $testname"
                    echo "DETAIL   Expected: functions to purify"
                    echo "DETAIL   Got: nothing purifiable"
                fi
            elif [ "$parent_dir" = "should_not_purify" ]; then
                if [ -z "$output" ]; then
                    echo "PASS ✓ [purify/should_not_purify] $testname"
                else
                    echo "FAIL ✗ [purify/should_not_purify] $testname"
                    echo "DETAIL   Expected: nothing purifiable"
                    echo "$output" | sed 's/^/DETAIL     /'
                fi
            fi
        fi

    elif [ "$grandparent" = "parser" ]; then
        output=$(run_blorp_capture compile --no-format --ast "$test")
        exit_code=$?
        if [ "$parent_dir" = "should_pass" ]; then
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [should_pass/parser] $testname"
                echo "DETAIL   Parse test timed out after ${compiler_test_timeout}s"
            elif [ $exit_code -eq 0 ]; then
                echo "PASS ✓ [should_pass/parser] $testname"
            else
                echo "FAIL ✗ [should_pass/parser] $testname"
                echo "DETAIL   Expected: parse success"
                echo "DETAIL   Got: parse failed"
                echo "$output" | head -5 | sed 's/^/DETAIL     /'
            fi
        elif [ "$parent_dir" = "should_fail" ]; then
            if [ $exit_code -eq 124 ]; then
                echo "FAIL ✗ [should_fail/parser] $testname"
                echo "DETAIL   Parse test timed out after ${compiler_test_timeout}s"
                return
            elif [ $exit_code -eq 0 ]; then
                echo "FAIL ✗ [should_fail/parser] $testname"
                echo "DETAIL   Expected: parse failure"
                echo "DETAIL   Got: parse succeeded"
                return
            fi

            if check_error_expectations \
                "$test" "$output" "should_fail/parser" "$testname" \
                "Parse failed, but error message mismatch:"; then
                echo "PASS ✓ [should_fail/parser] $testname"
            fi
        fi

    elif [ "$parent_dir" = "should_pass" ]; then
        output=$(run_blorp_capture check --no-format "$test")
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "FAIL ✗ [should_pass/$grandparent] $testname"
            echo "DETAIL   Compilation timed out after ${compiler_test_timeout}s"
        elif [ $exit_code -eq 0 ]; then
            echo "PASS ✓ [should_pass/$grandparent] $testname"
        else
            echo "FAIL ✗ [should_pass/$grandparent] $testname"
            echo "DETAIL   Expected: compilation success"
            echo "DETAIL   Got: compilation failed"
            echo "$output" | head -5 | sed 's/^/DETAIL     /'
        fi

    elif [ "$parent_dir" = "should_fail" ]; then
        output=$(run_blorp_capture check --no-format "$test")
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "FAIL ✗ [should_fail/$grandparent] $testname"
            echo "DETAIL   Compilation timed out after ${compiler_test_timeout}s"
            return
        elif [ $exit_code -eq 0 ]; then
            echo "FAIL ✗ [should_fail/$grandparent] $testname"
            echo "DETAIL   Expected: compilation failure"
            echo "DETAIL   Got: compilation succeeded"
            return
        fi

        if check_error_expectations \
            "$test" "$output" "should_fail/$grandparent" "$testname" \
            "Compilation failed, but error message mismatch:"; then
            echo "PASS ✓ [should_fail/$grandparent] $testname"
        fi
    fi
}

# ─── Run tests in parallel chunks ───────────────────────────────

run_chunk() {
    local chunk_id="$1"
    shift
    local result_file="$RESULT_DIR/chunk_$chunk_id"
    for test in "$@"; do
        run_test "$test"
    done > "$result_file"
}

# Distribute tests round-robin across chunks
declare -a chunks
for i in "${!test_files[@]}"; do
    chunk_idx=$((i % NJOBS))
    chunks[$chunk_idx]+="${test_files[$i]}"$'\n'
done

# Launch chunks in background
for chunk_id in $(seq 0 $((NJOBS - 1))); do
    chunk_tests=()
    while IFS= read -r line; do
        [ -n "$line" ] && chunk_tests+=("$line")
    done <<< "${chunks[$chunk_id]}"
    if [ ${#chunk_tests[@]} -gt 0 ]; then
        run_chunk "$chunk_id" "${chunk_tests[@]}" &
        pids+=($!)
    fi
done

# Wait for all chunks
for pid in "${pids[@]}"; do
    wait "$pid" || true
done
pids=()

# ─── Collect and display results ────────────────────────────────

passed=0
failed=0

# Read all chunk files in order, print results
for chunk_id in $(seq 0 $((NJOBS - 1))); do
    result_file="$RESULT_DIR/chunk_$chunk_id"
    [ -f "$result_file" ] || continue
    while IFS= read -r line; do
        case "$line" in
            PASS\ *)
                if $verbose; then
                    echo "${line#PASS }"
                fi
                ((passed++))
                ;;
            FAIL\ *)  echo "${line#FAIL }"; ((failed++)) ;;
            DETAIL\ *) echo "${line#DETAIL }" ;;
        esac
    done < "$result_file"
done

# ─── Run codegen audit tests ────────────────────────────────────

codegen_audit="tests/test_compiler/codegen_audit/run_codegen_audit.sh"
if [ -x "$codegen_audit" ]; then
    echo ""
    echo "Codegen Audit"
    codegen_output_file="$RESULT_DIR/codegen_audit"
    "$codegen_audit" "$BLORP_BIN" > "$codegen_output_file" 2>&1 &
    codegen_pid=$!
    wait "$codegen_pid"
    codegen_exit=$?
    codegen_pid=""
    codegen_output=$(cat "$codegen_output_file")
    codegen_cases=0

    while IFS= read -r line; do
        case "$line" in
            PASS:*)
                if $verbose; then
                    echo "✓ [codegen_audit] ${line#PASS: }"
                fi
                ((passed++))
                ((total++))
                ((codegen_cases++))
                ;;
            FAIL:*)
                echo "✗ [codegen_audit] ${line#FAIL: }"
                ((failed++))
                ((total++))
                ((codegen_cases++))
                ;;
            Results:*|"")
                ;;
            *)
                echo "$line" | sed 's/^/  /'
                ;;
        esac
    done <<< "$codegen_output"

    if [ $codegen_exit -ne 0 ] && [ $codegen_cases -eq 0 ]; then
        echo "✗ [codegen_audit] runner failed before reporting test results"
        echo "$codegen_output" | head -10 | sed 's/^/  /'
        ((failed++))
        ((total++))
    fi
else
    echo ""
    echo "✗ [codegen_audit] missing runner: $codegen_audit"
    ((failed++))
    ((total++))
fi

# Check for should_fail tests missing EXPECT annotations
missing_expect=0
for f in $(find tests/test_compiler -path "*/should_fail/*.brp" -not -path "*/format/*" -type f); do
    if ! grep -Eq "^-- EXPECT(:|-CONTAINS:)" "$f"; then
        echo "⚠ Missing EXPECT annotation: $(basename "$f")"
        ((missing_expect++))
    fi
done

echo ""
if [ $missing_expect -gt 0 ]; then
    echo "⚠ $missing_expect should_fail test(s) without -- EXPECT: annotations (format tests excluded)"
fi
if [ $failed -eq 0 ]; then
    echo "BLORP_GATE_RESULT gate=compiler status=PASS passed=$passed failed=0 tests=$total"
    echo "✓ All $total compiler tests passed"
    exit 0
else
    echo "BLORP_GATE_RESULT gate=compiler status=FAIL passed=$passed failed=$failed tests=$total"
    echo "✗ $passed/$total compiler tests passed ($failed failed)"
    exit 1
fi
