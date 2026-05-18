#!/usr/bin/env bash
# Public CLI smoke and exit-code contract tests.

set -u

cd "$(dirname "$0")/.."

BLORP_BIN="${BLORP_BIN:-./blorp}"
CLI_TIMEOUT="${BLORP_CLI_TEST_TIMEOUT:-${BLORP_TEST_TIMEOUT:-30}}"
TMPDIR_CLI=$(mktemp -d "${TMPDIR:-/tmp}/blorp_cli.XXXXXX") || exit 1
PASS=0
FAIL=0
TOTAL=0
RUN_OUTPUT=""
RUN_CODE=0

case "$CLI_TIMEOUT" in
    ''|*[!0-9]*)
        echo "Error: BLORP_CLI_TEST_TIMEOUT must be a non-negative integer." >&2
        exit 1
        ;;
esac

cleanup() {
    rm -rf "$TMPDIR_CLI"
}
trap cleanup EXIT

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

run_capture() {
    local stdin_file="$1"
    shift
    local output_file pid start timed_out code
    output_file=$(mktemp "$TMPDIR_CLI/output.XXXXXX") || exit 1
    timed_out=false

    if [ -n "$stdin_file" ]; then
        "$@" < "$stdin_file" > "$output_file" 2>&1 &
    else
        "$@" > "$output_file" 2>&1 &
    fi
    pid=$!

    if [ "$CLI_TIMEOUT" -gt 0 ]; then
        start=$SECONDS
        while jobs -pr | grep -q "^$pid$"; do
            if [ $((SECONDS - start)) -ge "$CLI_TIMEOUT" ]; then
                timed_out=true
                terminate_process_tree "$pid" TERM
                sleep 1
                terminate_process_tree "$pid" KILL
                break
            fi
            sleep 0.1
        done
    fi

    wait "$pid" 2>/dev/null
    code=$?
    RUN_OUTPUT=$(cat "$output_file")
    rm -f "$output_file"

    if $timed_out; then
        RUN_CODE=124
    else
        RUN_CODE=$code
    fi
}

record_pass() {
    PASS=$((PASS + 1))
    echo "PASS: $1"
}

record_fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL: $1"
    if [ -n "${2:-}" ]; then
        echo "$2" | sed 's/^/  /'
    fi
}

expect_exit() {
    local name="$1"
    local expected="$2"
    shift 2

    TOTAL=$((TOTAL + 1))
    run_capture "" "$@"

    if [ "$RUN_CODE" -eq "$expected" ]; then
        record_pass "$name"
    else
        record_fail "$name" "expected exit $expected, got $RUN_CODE
$RUN_OUTPUT"
    fi
}

expect_stdin_exit() {
    local name="$1"
    local expected="$2"
    local stdin="$3"
    shift 3

    TOTAL=$((TOTAL + 1))
    local stdin_file
    stdin_file=$(mktemp "$TMPDIR_CLI/stdin.XXXXXX") || exit 1
    printf "%s" "$stdin" > "$stdin_file"
    run_capture "$stdin_file" "$@"
    rm -f "$stdin_file"

    if [ "$RUN_CODE" -eq "$expected" ]; then
        record_pass "$name"
    else
        record_fail "$name" "expected exit $expected, got $RUN_CODE
$RUN_OUTPUT"
    fi
}

expect_output_contains() {
    local name="$1"
    local expected_code="$2"
    local needle="$3"
    shift 3

    TOTAL=$((TOTAL + 1))
    run_capture "" "$@"

    if [ "$RUN_CODE" -ne "$expected_code" ]; then
        record_fail "$name" "expected exit $expected_code, got $RUN_CODE
$RUN_OUTPUT"
    elif echo "$RUN_OUTPUT" | grep -qF "$needle"; then
        record_pass "$name"
    else
        record_fail "$name" "missing output: $needle
$RUN_OUTPUT"
    fi
}

valid_prog="$TMPDIR_CLI/valid.brp"
args_prog="$TMPDIR_CLI/args.brp"
invalid_prog="$TMPDIR_CLI/invalid.brp"
failing_test="$TMPDIR_CLI/failing_test.brp"
compiled_c="$TMPDIR_CLI/valid.c"
check_dir_ok="$TMPDIR_CLI/check_dir_ok"
check_dir_bad="$TMPDIR_CLI/check_dir_bad"

mkdir -p "$check_dir_ok/nested" "$check_dir_bad/nested"

cat > "$valid_prog" <<'BRP'
func main(args: List[String]) -> Int:
	print("cli ok")
	0
BRP

cat > "$args_prog" <<'BRP'
func main(args: List[String]) -> Int:
	print(args.join("|"))
	0
BRP

cat > "$invalid_prog" <<'BRP'
func main(args: List[String]) -> Int:
	"not an int"
BRP

cp "$valid_prog" "$check_dir_ok/root.brp"
cp "$valid_prog" "$check_dir_ok/nested/child.brp"
cp "$valid_prog" "$check_dir_bad/root.brp"
cp "$invalid_prog" "$check_dir_bad/nested/child.brp"

cat > "$failing_test" <<'BRP'
import:
	test: TestSuite

func test_false() -> Bool:
	False

tests: TestSuite = {
	description = "CLI failing test",
	tests = [("false", test_false)]
}
BRP

expect_exit "top-level help" 0 "$BLORP_BIN" --help
expect_exit "top-level version" 0 "$BLORP_BIN" --version
expect_exit "top-level missing command" 1 "$BLORP_BIN"
expect_exit "unknown command" 1 "$BLORP_BIN" does-not-exist

expect_exit "check success" 0 "$BLORP_BIN" check --no-format "$valid_prog"
expect_exit "check directory success" 0 "$BLORP_BIN" check --no-format "$check_dir_ok"
expect_exit "check directory failure" 1 "$BLORP_BIN" check --no-format "$check_dir_bad"
expect_exit "check type failure" 1 "$BLORP_BIN" check --no-format "$invalid_prog"
expect_exit "check missing file arg" 1 "$BLORP_BIN" check

expect_exit "compile success" 0 "$BLORP_BIN" compile --no-format -o "$compiled_c" "$valid_prog"
if [ -f "$compiled_c" ]; then
    TOTAL=$((TOTAL + 1))
    record_pass "compile writes requested output"
else
    TOTAL=$((TOTAL + 1))
    record_fail "compile writes requested output" "missing $compiled_c"
fi
external_runtime_c="$TMPDIR_CLI/external_runtime.c"
expect_exit "compile no embedded runtime" 0 "$BLORP_BIN" compile --no-format --no-embed-runtime -o "$external_runtime_c" "$valid_prog"
if [ ! -f "$external_runtime_c" ]; then
    TOTAL=$((TOTAL + 1))
    record_fail "compile no embedded runtime omits runtime body" "missing $external_runtime_c"
elif grep -qF "blorp Runtime" "$external_runtime_c"; then
    TOTAL=$((TOTAL + 1))
    record_fail "compile no embedded runtime omits runtime body" "runtime body was embedded"
else
    TOTAL=$((TOTAL + 1))
    record_pass "compile no embedded runtime omits runtime body"
fi
expect_exit "compile type failure" 1 "$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/invalid.c" "$invalid_prog"
expect_output_contains "compile no-emit removed" 1 "use 'blorp check <file.brp>'" "$BLORP_BIN" compile --no-emit "$valid_prog"
expect_output_contains "compile check removed" 1 "use 'blorp check <file.brp>'" "$BLORP_BIN" compile --check "$valid_prog"
expect_output_contains "compile profile removed" 1 "use 'blorp compile --time-phases <file.brp>'" "$BLORP_BIN" compile --profile "$valid_prog"
expect_output_contains "compile core emit removed" 1 "use 'blorp compile <file.brp>'" "$BLORP_BIN" compile --core-emit "$valid_prog"

expect_exit "run success" 0 "$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"
expect_output_contains "run passes args without separator" 0 "alpha|--beta|gamma" "$BLORP_BIN" run --no-format --timeout 5 "$args_prog" alpha --beta gamma
expect_output_contains "run still accepts arg separator" 0 "one|two" "$BLORP_BIN" run --no-format --timeout 5 "$args_prog" -- one two
expect_exit "run type failure" 1 "$BLORP_BIN" run --no-format --timeout 5 "$invalid_prog"
expect_exit "run bad timeout" 1 "$BLORP_BIN" run --timeout not-an-int "$valid_prog"

expect_exit "test success" 0 "$BLORP_BIN" test --no-cache --no-format --timeout 5 tests/test_blorp/types/test_bool.brp
expect_exit "test failure" 1 "$BLORP_BIN" test --no-cache --no-format --timeout 5 "$failing_test"
expect_exit "test bad timeout" 1 "$BLORP_BIN" test --timeout not-an-int tests/test_blorp/types/test_bool.brp

expect_exit "format check success" 0 "$BLORP_BIN" format --check "$valid_prog"
expect_exit "format check failure" 1 "$BLORP_BIN" format --check tests/test_compiler/format/should_fail/bad_spacing.brp
expect_exit "format missing file arg" 1 "$BLORP_BIN" format --check

expect_output_contains "repl help" 0 "Usage: blorp repl" "$BLORP_BIN" repl --help
expect_stdin_exit "repl quit" 0 ":quit
" "$BLORP_BIN" repl
expect_exit "repl rejects unknown option" 1 "$BLORP_BIN" repl --bogus

expect_output_contains "lsp help" 0 "Usage: blorp lsp" "$BLORP_BIN" lsp --help
expect_exit "lsp eof shutdown" 0 "$BLORP_BIN" lsp
expect_exit "lsp rejects unknown option" 1 "$BLORP_BIN" lsp --bogus

echo ""
echo "Results: $PASS passed, $FAIL failed ($TOTAL CLI checks)"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
