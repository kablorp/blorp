#!/usr/bin/env bash
# Public CLI smoke and exit-code contract tests.

set -u

cd "$(dirname "$0")/../../.."

usage() {
    cat <<'EOF'
Usage: blorp/test/cli/test_cli.sh [--all|--smoke] [--timeout SECONDS] [--gate-name NAME]

Options:
  --all                Run the full CLI integration set, including package and formatter tool checks.
  --smoke              Run public command-surface smoke checks only.
  --timeout SECONDS    Per-command timeout. Defaults to BLORP_TEST_TIMEOUT or 60.
  --gate-name NAME     Gate name emitted in the BLORP_GATE_RESULT summary.
EOF
}

CLI_MODE="all"
CLI_GATE_NAME="cli"
CLI_TIMEOUT="${BLORP_TEST_TIMEOUT:-60}"
while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            CLI_MODE="all"
            shift
            ;;
        --smoke)
            CLI_MODE="smoke"
            shift
            ;;
        --timeout)
            if [ $# -lt 2 ]; then
                echo "Missing value for --timeout" >&2
                usage >&2
                exit 1
            fi
            CLI_TIMEOUT="$2"
            shift 2
            ;;
        --gate-name)
            if [ $# -lt 2 ]; then
                echo "Missing value for --gate-name" >&2
                usage >&2
                exit 1
            fi
            CLI_GATE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

BLORP_BIN="${BLORP_BIN:-bin/blorp}"
if [[ "$BLORP_BIN" = /* ]]; then
    BLORP_BIN_ABS="$BLORP_BIN"
else
    BLORP_BIN_ABS="$PWD/${BLORP_BIN#./}"
fi
# Smoke mode is the default local-loop shape used by scripts/test. Full mode
# adds broader process/compiler integration plus each command owner's integration gate.
run_deep_checks=false
if [ "$CLI_MODE" = "all" ]; then
    run_deep_checks=true
fi
TMPDIR_CLI=$(mktemp -d "${TMPDIR:-/tmp}/blorp_cli.XXXXXX") || exit 1
PASS=0
FAIL=0
TOTAL=0
RUN_OUTPUT=""
RUN_CODE=0
CHILD_PIDS=()
BLORP_DIRECT_TEST_ENV=(
    env
    -u BLORP_TEST_TIMEOUT
    -u BLORP_TIMEOUT
    -u BLORP_SANITIZE
    -u BLORP_LEAK_CHECK
    -u BLORP_NO_FORMAT
    -u BLORP_GATE_RESULT
    -u BLORP_TEST_RETAIN_RUN_ARTIFACTS
    -u BLORP_TEST_COMPILER_BIN
    -u BLORP_TEST_TIMINGS
)

case "$CLI_TIMEOUT" in
    ''|*[!0-9]*)
        echo "Error: --timeout must be a non-negative integer." >&2
        exit 1
        ;;
esac

cleanup() {
    local pid
    set +u
    for pid in "${CHILD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    set -u
    rm -rf "$TMPDIR_CLI"
}
trap cleanup EXIT

forget_child_pid() {
    local target="$1"
    local tracked
    local remaining=()

    for tracked in "${CHILD_PIDS[@]}"; do
        if [ "$tracked" != "$target" ]; then
            remaining+=("$tracked")
        fi
    done

    set +u
    CHILD_PIDS=("${remaining[@]}")
    set -u
}

list_child_pids() {
    local parent="$1"
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$parent" 2>/dev/null || true
    else
        ps -o pid= -P "$parent" 2>/dev/null | tr -d ' ' || true
    fi
}

pid_is_running_non_zombie() {
    local pid="$1"
    local state
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    case "$state" in
        Z*) return 1 ;;
        *) return 0 ;;
    esac
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

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed ($TOTAL CLI checks)"
    if [ "$FAIL" -gt 0 ]; then
        echo "BLORP_GATE_RESULT gate=$CLI_GATE_NAME status=FAIL passed=$PASS failed=$FAIL tests=$TOTAL"
        return 1
    fi
    echo "BLORP_GATE_RESULT gate=$CLI_GATE_NAME status=PASS passed=$PASS failed=0 tests=$TOTAL"
    return 0
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
    elif grep -qF "$needle" <<<"$RUN_OUTPUT"; then
        record_pass "$name"
    else
        record_fail "$name" "missing output: $needle
$RUN_OUTPUT"
    fi
}

expect_output_excludes() {
    local name="$1"
    local expected_code="$2"
    local needle="$3"
    shift 3

    TOTAL=$((TOTAL + 1))
    run_capture "" "$@"

    if [ "$RUN_CODE" -ne "$expected_code" ]; then
        record_fail "$name" "expected exit $expected_code, got $RUN_CODE
$RUN_OUTPUT"
    elif grep -qF "$needle" <<<"$RUN_OUTPUT"; then
        record_fail "$name" "unexpected output: $needle
$RUN_OUTPUT"
    else
        record_pass "$name"
    fi
}

expect_test_signal_exit() {
    local name="$1"
    local signal_name="$2"
    local expected_code="$3"
    local marker="$4"
    local descendant_marker="$5"
    shift 5
    local output_file pid start code child_pids child descendant survivor timed_out signal_wait_timeout attempts
    output_file=$(mktemp "$TMPDIR_CLI/output.XXXXXX") || exit 1
    rm -f "$marker"
    rm -f "$descendant_marker"

    TOTAL=$((TOTAL + 1))
    "$@" > "$output_file" 2>&1 &
    pid=$!
    CHILD_PIDS+=("$pid")
    start=$SECONDS

    while [ ! -f "$marker" ] && kill -0 "$pid" 2>/dev/null; do
        if [ "$CLI_TIMEOUT" -gt 0 ] \
            && [ $((SECONDS - start)) -ge "$CLI_TIMEOUT" ]; then
            break
        fi
        sleep 0.05
    done

    if [ ! -f "$marker" ]; then
        terminate_process_tree "$pid" TERM
        wait "$pid" 2>/dev/null || true
        forget_child_pid "$pid"
        RUN_OUTPUT=$(cat "$output_file")
        rm -f "$output_file"
        record_fail "$name" "native test did not reach its signal checkpoint
$RUN_OUTPUT"
        return
    fi

    child_pids=$(list_child_pids "$pid")
    descendant=$(cat "$descendant_marker" 2>/dev/null || true)
    kill -"$signal_name" "$pid" 2>/dev/null || true
    timed_out=false
    signal_wait_timeout="$CLI_TIMEOUT"
    if [ "$signal_wait_timeout" -eq 0 ]; then
        signal_wait_timeout=30
    fi
    start=$SECONDS

    while jobs -pr | grep -q "^$pid$"; do
        if [ $((SECONDS - start)) -ge "$signal_wait_timeout" ]; then
            timed_out=true
            terminate_process_tree "$pid" TERM
            sleep 1
            terminate_process_tree "$pid" KILL
            break
        fi
        sleep 0.05
    done

    wait "$pid" 2>/dev/null
    code=$?
    forget_child_pid "$pid"
    RUN_OUTPUT=$(cat "$output_file")
    rm -f "$output_file"

    survivor=""
    for child in $child_pids $descendant; do
        [ -n "$child" ] || continue
        attempts=0
        while pid_is_running_non_zombie "$child" && [ "$attempts" -lt 40 ]; do
            sleep 0.05
            attempts=$((attempts + 1))
        done
        if pid_is_running_non_zombie "$child"; then
            survivor="$child"
            break
        fi
    done

    if $timed_out; then
        record_fail "$name" "compiler did not exit within ${signal_wait_timeout}s after $signal_name
$RUN_OUTPUT"
    elif [ "$code" -ne "$expected_code" ]; then
        record_fail "$name" "expected exit $expected_code, got $code
$RUN_OUTPUT"
    elif [ -n "$survivor" ]; then
        record_fail "$name" "child process $survivor survived compiler interruption"
    else
        record_pass "$name"
    fi
}

expect_test_tty_fallback() {
    local name="$1"
    local expected_code="$2"
    local needle="$3"
    shift 3
    local output_file code
    output_file=$(mktemp "$TMPDIR_CLI/tty-output.XXXXXX") || exit 1

    TOTAL=$((TOTAL + 1))
    python3 - "$output_file" "$CLI_TIMEOUT" "$@" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

output_path = sys.argv[1]
timeout = int(sys.argv[2]) or 30
command = sys.argv[3:]
pid, descriptor = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

output = bytearray()
deadline = time.monotonic() + timeout
status = None
while status is None and time.monotonic() < deadline:
    readable, _, _ = select.select([descriptor], [], [], 0.05)
    if readable:
        try:
            chunk = os.read(descriptor, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b""
        if chunk:
            output.extend(chunk)
    waited, candidate = os.waitpid(pid, os.WNOHANG)
    if waited == pid:
        status = candidate

if status is None:
    os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    code = 124
else:
    code = os.waitstatus_to_exitcode(status)

try:
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            break
        output.extend(chunk)
except OSError as error:
    if error.errno != errno.EIO:
        raise
os.close(descriptor)
with open(output_path, "wb") as output_file:
    output_file.write(output)
raise SystemExit(code)
PY
    code=$?
    RUN_OUTPUT=$(cat "$output_file")
    rm -f "$output_file"

    if [ "$code" -ne "$expected_code" ]; then
        record_fail "$name" "expected exit $expected_code, got $code
$RUN_OUTPUT"
    elif echo "$RUN_OUTPUT" | grep -qF "$needle"; then
        record_pass "$name"
    else
        record_fail "$name" "missing output: $needle
$RUN_OUTPUT"
    fi
}

expect_test_binary_streams() {
    local name="$1"
    shift
    local stdout_file stderr_file code
    stdout_file=$(mktemp "$TMPDIR_CLI/stdout.XXXXXX") || exit 1
    stderr_file=$(mktemp "$TMPDIR_CLI/stderr.XXXXXX") || exit 1
    printf 'preexisting-stdout\n' > "$stdout_file"
    printf 'preexisting-stderr\n' > "$stderr_file"

    TOTAL=$((TOTAL + 1))
    "$@" >> "$stdout_file" 2>> "$stderr_file"
    code=$?

    if [ "$code" -ne 0 ]; then
        record_fail "$name" "expected exit 0, got $code
$(cat "$stderr_file")"
    elif python3 - "$stdout_file" "$stderr_file" <<'PY'
import pathlib
import sys

stdout = pathlib.Path(sys.argv[1]).read_bytes()
stderr = pathlib.Path(sys.argv[2]).read_bytes()
expected_stdout = (
    b"preexisting-stdout\n"
    b"\n>> CLI binary output test Tests\n"
    b"\x00A\xff  [PASS] writes binary streams\n"
    b"\nAll 1 tests passed\n"
)
if stdout != expected_stdout:
    raise SystemExit(f"stdout mismatch: {stdout!r}")
if stderr != b"preexisting-stderr\ncandidate-stderr-marker\n":
    raise SystemExit(f"stderr mismatch: {stderr!r}")
PY
    then
        record_pass "$name"
    else
        record_fail "$name" "captured stdout/stderr bytes did not match"
    fi

    rm -f "$stdout_file" "$stderr_file"
}


expect_process_inheritance() {
    local name="$1"
    local stdin_line="$2"
    local expected_stdout="$3"
    local expected_stderr="$4"
    shift 4
    local stdin_file stdout_file stderr_file code
    stdin_file=$(mktemp "$TMPDIR_CLI/stdin.XXXXXX") || exit 1
    stdout_file=$(mktemp "$TMPDIR_CLI/stdout.XXXXXX") || exit 1
    stderr_file=$(mktemp "$TMPDIR_CLI/stderr.XXXXXX") || exit 1
    printf '%s\n' "$stdin_line" > "$stdin_file"

    TOTAL=$((TOTAL + 1))
    "$@" < "$stdin_file" > "$stdout_file" 2> "$stderr_file"
    code=$?

    if [ "$code" -ne 0 ]; then
        record_fail "$name" "expected exit 0, got $code
$(cat "$stderr_file")"
    elif python3 - "$stdout_file" "$stderr_file" "$expected_stdout" "$expected_stderr" <<'PY'
import pathlib
import sys

stdout = pathlib.Path(sys.argv[1]).read_bytes()
stderr = pathlib.Path(sys.argv[2]).read_bytes()
expected_stdout = sys.argv[3].encode()
expected_stderr = sys.argv[4].encode()
if stdout != expected_stdout:
    raise SystemExit(f"stdout mismatch: {stdout!r}")
if stderr != expected_stderr:
    raise SystemExit(f"stderr mismatch: {stderr!r}")
PY
    then
        record_pass "$name"
    else
        record_fail "$name" "inherited stdout/stderr bytes did not match"
    fi

    rm -f "$stdin_file" "$stdout_file" "$stderr_file"
}


expect_test_closed_stdout_failure() {
    local name="$1"
    shift
    local stderr_file code output
    stderr_file=$(mktemp "$TMPDIR_CLI/stderr.XXXXXX") || exit 1

    TOTAL=$((TOTAL + 1))
    "$@" 1>&- 2> "$stderr_file"
    code=$?
    output=$(cat "$stderr_file")
    rm -f "$stderr_file"

    if [ "$code" -ne 1 ]; then
        record_fail "$name" "expected exit 1, got $code
$output"
    elif echo "$output" | grep -qF "cannot forward captured test output"; then
        record_pass "$name"
    else
        record_fail "$name" "missing output forwarding diagnostic
$output"
    fi
}

expect_test_environment_stays_blorp_owned() {
    local variable="$1"
    local value="$2"

    expect_output_contains "test environment $variable remains Blorp-owned" 0 \
        "[PASS]" \
        "${BLORP_DIRECT_TEST_ENV[@]}" \
        "$variable=$value" \
        "$BLORP_BIN" test --suite --timeout 5 \
        blorp/test/runtime/types/test_bool.brp
}

expect_test_session_counters() {
    local name="$1"
    local marker="$2"
    local discovered_files="$3"
    local declared_suites="$4"
    local aggregate_suite_harnesses="$5"
    local suite_files="$6"
    local native_executions="$7"
    local individual_source_files="$8"
    shift 8

    TOTAL=$((TOTAL + 1))
    run_capture "" "$@"
    if [ "$RUN_CODE" -eq 0 ] \
        && grep -qF "$marker" <<<"$RUN_OUTPUT" \
        && printf '%s\n' "$RUN_OUTPUT" | python3 -c '
import json
import sys

prefix = "BLORP_TEST_SESSION_COUNTER "
records = [json.loads(line[len(prefix):]) for line in sys.stdin if line.startswith(prefix)]
if len(records) != 1:
    raise SystemExit(f"expected one session counter record, got {len(records)}")
record = records[0]
counters = record["counters"]
expected = {
    "discovered_runnable_files": int(sys.argv[1]),
    "unique_discovered_runnable_source_identities": int(sys.argv[1]),
    "declared_test_suites": int(sys.argv[2]),
    "planned_aggregate_suite_harnesses": int(sys.argv[3]),
    "planned_combined_suite_files": int(sys.argv[4]),
    "planned_combined_native_executions": int(sys.argv[5]),
    "planned_individual_source_files": int(sys.argv[6]),
}
if record.get("schema_version") != 2 or record.get("event") != "session_totals":
    raise SystemExit(f"unexpected counter envelope: {record}")
expected_keys = set(expected) | {"retained_runnable_source_bytes"}
if set(counters) != expected_keys:
    raise SystemExit(f"unexpected counter fields: {sorted(counters)}")
if counters.get("retained_runnable_source_bytes", 0) <= 0:
    raise SystemExit("retained source byte count must be positive")
for key, value in expected.items():
    if counters.get(key) != value:
        raise SystemExit(f"{key}: expected {value}, got {counters.get(key)}")
' "$discovered_files" "$declared_suites" "$aggregate_suite_harnesses" \
        "$suite_files" "$native_executions" "$individual_source_files"
    then
        record_pass "$name"
    else
        record_fail "$name" "expected one exact Blorp-owned session counter record, got exit $RUN_CODE
$RUN_OUTPUT"
    fi
}

expect_formatter_output_contains() {
    local name="$1"
    local expected_code="$2"
    local needle="$3"
    shift 3

    if $formatter_tool_ready; then
        expect_output_contains "$name" "$expected_code" "$needle" \
            "$formatter_tool_bin" "$@"
    else
        TOTAL=$((TOTAL + 1))
        record_fail "$name" "formatter tool did not compile"
    fi
}

verify_stage_two_direct_test_route() {
    local output code
    TOTAL=$((TOTAL + 1))
    output=$(BLORP_BIN="$BLORP_BIN" blorp/test/cli/test_cli_stage_two.sh --timeout "$CLI_TIMEOUT" 2>&1)
    code=$?

    if [ "$code" -eq 0 ]; then
        record_pass "stage-two compiler exercises Blorp-owned test route"
    else
        record_fail "stage-two compiler exercises Blorp-owned test route" "$output"
    fi
}

verify_package_lifecycle() {
    local output code
    TOTAL=$((TOTAL + 1))
    output=$(BLORP_BIN="$BLORP_BIN" blorp/test/package/test_package.sh \
        --timeout "$CLI_TIMEOUT" --gate-name package 2>&1)
    code=$?

    if [ "$code" -eq 0 ]; then
        record_pass "package-owned lifecycle integration"
    else
        record_fail "package-owned lifecycle integration" "$output"
    fi
}

valid_prog="$TMPDIR_CLI/valid.brp"
explicit_opaque_prog="$TMPDIR_CLI/explicit_opaque.brp"
formatted_opaque_prog="$TMPDIR_CLI/formatted_opaque.brp"
empty_prog="$TMPDIR_CLI/empty.brp"
invalid_prog="$TMPDIR_CLI/invalid.brp"
parse_invalid_prog="$TMPDIR_CLI/parse_invalid.brp"
failing_test="$TMPDIR_CLI/failing_test.brp"
failing_doctest="$TMPDIR_CLI/failing_doctest.brp"
compile_failing_doctest="$TMPDIR_CLI/compile_failing_doctest.brp"
main_doctest="$TMPDIR_CLI/main_doctest.brp"
wrong_typed_test="$TMPDIR_CLI/wrong_typed_test.brp"
local_alias_test="$TMPDIR_CLI/local_alias_test.brp"
partial_pass_test="$TMPDIR_CLI/partial_pass_test.brp"
partial_timeout_test="$TMPDIR_CLI/partial_timeout_test.brp"
compile_failing_test="$TMPDIR_CLI/compile_failing_test.brp"
timeout_test="$TMPDIR_CLI/timeout_test.brp"
repeat_test="$TMPDIR_CLI/repeat_test.brp"
signal_test="$TMPDIR_CLI/signal_test.brp"
signal_marker="$TMPDIR_CLI/signal_test.started"
signal_descendant_marker="$TMPDIR_CLI/signal_test.descendant"
signal_helper="$TMPDIR_CLI/signal_test_helper.sh"
host_discovery_signal_marker="$TMPDIR_CLI/host_discovery.started"
host_discovery_descendant_marker="$TMPDIR_CLI/host_discovery.descendant"
child_signal_test="$TMPDIR_CLI/child_signal_test.brp"
binary_output_test="$TMPDIR_CLI/binary_output_test.brp"
stdin_test="$TMPDIR_CLI/stdin_test.brp"
multi_suite_test_dir="$TMPDIR_CLI/multi_suite_tests"
mixed_test_dir="$TMPDIR_CLI/mixed_tests"
same_stem_doctest_left_dir="$TMPDIR_CLI/same_stem_doctests/types"
same_stem_doctest_right_dir="$TMPDIR_CLI/same_stem_doctests/text"
same_stem_doctest_left="$same_stem_doctest_left_dir/sample.brp"
same_stem_doctest_right="$same_stem_doctest_right_dir/sample.brp"
repeat_marker="$TMPDIR_CLI/repeat_marker.txt"
compiled_c="$TMPDIR_CLI/valid.c"
invariant_at_a_glance_c="$TMPDIR_CLI/invariant-at-a-glance.c"
invariant_concurrent_duration_c="$TMPDIR_CLI/invariant-concurrent-duration.c"
internal_synthetic_binary="$TMPDIR_CLI/internal-synthetic-program"
profiled_c="$TMPDIR_CLI/profiled.c"
profile_window_prog="$TMPDIR_CLI/profile_window.brp"
profile_window_c="$TMPDIR_CLI/profile_window.c"
profile_window_bin="$TMPDIR_CLI/profile_window"
resolved_identity_prog="$TMPDIR_CLI/resolved_identity.brp"
late_core_dump="$TMPDIR_CLI/late-core.dump"
late_stopped_c="$TMPDIR_CLI/late-stopped.c"
check_dir_ok="$TMPDIR_CLI/check_dir_ok"
check_dir_bad="$TMPDIR_CLI/check_dir_bad"
check_dir_empty="$TMPDIR_CLI/check_dir_empty"

mkdir -p "$check_dir_ok/nested" "$check_dir_bad/nested" "$check_dir_empty"
mkdir -p "$multi_suite_test_dir"
cp blorp/test/runtime/types/test_bool.brp "$multi_suite_test_dir/a_bool.brp"
cp blorp/test/runtime/types/test_char.brp "$multi_suite_test_dir/b_char.brp"
mkdir -p "$mixed_test_dir"
mkdir -p "$same_stem_doctest_left_dir" "$same_stem_doctest_right_dir"
cp blorp/test/runtime/types/test_bool.brp "$mixed_test_dir/a_bool.brp"
cat >> "$mixed_test_dir/a_bool.brp" <<'BRP'


---
Doctest on the same source as a TestSuite.

doctests:
    :: runs after its suite
    True
---
pure func mixed_doctest() -> Bool:
	True
BRP
cat > "$mixed_test_dir/helper.brp" <<'BRP'
pure func helper_value() -> Int:
	42
BRP
cat > "$mixed_test_dir/b_doctest.brp" <<'BRP'
---
Return the documented value.

doctests:
    :: imports a doctest-only dependency
    import:
        ./helper: helper_value

    documented_value() == helper_value()
---
pure func documented_value() -> Int:
	42
BRP
cat > "$same_stem_doctest_left" <<'BRP'
---
Left namespace example.

doctests:
    :: retains the left namespace
    left_answer() == 1
---
pure func left_answer() -> Int:
	1
BRP
cat > "$same_stem_doctest_right" <<'BRP'
---
Right namespace example.

doctests:
    :: retains the right namespace
    right_answer() == 2
---
pure func right_answer() -> Int:
	2
BRP

cat > "$valid_prog" <<'BRP'
func main(args: List[String]) -> Int:
	print("cli ok")
	0
BRP

cat > "$explicit_opaque_prog" <<'BRP'
opaque type UserId = Int


pure func user_id(raw: Int) -> UserId:
	into_opaque UserId(raw)


pure func user_id_value(value: UserId) -> Int:
	from_opaque UserId(value)


pure func into(value: Int) -> Int:
	value


func main(args: List[String]) -> Int:
	if into(user_id_value(user_id(42))) == 42:
		0
	else:
		1
BRP

cat > "$profile_window_prog" <<'BRP'
import:
	channel: Channel, channel, recv, send
	instrumentation: begin_function_profile_window, end_function_profile_window


private pure func profile_window_setup_probe(value: Int) -> Int:
	value + 1


private pure func profile_window_measured_probe(value: Int) -> Int:
	value + 2


private pure func profile_window_after_probe(value: Int) -> Int:
	value + 3


private func profile_window_crosses_begin_probe(
	started: Channel[Int],
	release: Channel[Int],
) -> Void:
	_ = send(started, 1)
	_ = recv(release)


private func profile_window_begin_controller(
	started: Channel[Int],
	release: Channel[Int],
) -> Void:
	_ = recv(started)
	begin_function_profile_window()
	_ = profile_window_measured_probe(1)
	_ = send(release, 1)


private func profile_window_crosses_end_probe(
	started: Channel[Int],
	release: Channel[Int],
) -> Void:
	_ = send(started, 1)
	_ = recv(release)


private func profile_window_end_controller(
	started: Channel[Int],
	release: Channel[Int],
) -> Void:
	_ = recv(started)
	end_function_profile_window()
	_ = send(release, 1)


func main(args: List[String]) -> Int:
	_ = profile_window_setup_probe(1)
	begin_started: Channel[Int] = channel(1)
	begin_release: Channel[Int] = channel(1)
	concurrent:
		begin_crossing = profile_window_crosses_begin_probe(begin_started, begin_release)
		begin_control = profile_window_begin_controller(begin_started, begin_release)
	_ = begin_crossing
	_ = begin_control

	end_started: Channel[Int] = channel(1)
	end_release: Channel[Int] = channel(1)
	concurrent:
		end_crossing = profile_window_crosses_end_probe(end_started, end_release)
		end_control = profile_window_end_controller(end_started, end_release)
	_ = end_crossing
	_ = end_control
	_ = profile_window_after_probe(1)

	if args.get(1) == Some("wait"):
		while True:
			_ = profile_window_after_probe(1)

	0
BRP

cat > "$resolved_identity_prog" <<'BRP'
import:
	channel: SendAttempt(SendAccepted), try_send_attempt


func main(args: List[String]) -> Int:
	ch: Channel[Int] = channel(1)
	attempt: SendAttempt = try_send_attempt(ch, 7)

	match attempt:
		SendAccepted:
			0
		_:
			1
BRP
: > "$empty_prog"

cat > "$invalid_prog" <<'BRP'
func main(args: List[String]) -> Int:
	"not an int"
BRP

cat > "$parse_invalid_prog" <<'BRP'
func bad(
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

cat > "$failing_doctest" <<'BRP'
---
An intentionally failing documented example.

doctests:
    :: reports false
    False
---
pure func documented_failure() -> Bool:
	False
BRP

cat > "$compile_failing_doctest" <<'BRP'
---
An intentionally ill-typed documented example.

doctests:
    :: fails during compilation
    1 + True
---
pure func documented_compile_failure() -> Bool:
	False
BRP

cat > "$main_doctest" <<'BRP'
---
An executable module with a documented example.

doctests:
    :: retains executable doctests
    answer() == 7
---
pure func answer() -> Int:
    7

func main(args: List[String]) -> Int:
    answer()
BRP

cat > "$wrong_typed_test" <<'BRP'
tests: Int = 1
BRP

cat > "$local_alias_test" <<'BRP'
import:
	test: TestSuite

type alias Suite = TestSuite

func passes() -> Bool:
	True

tests: Suite = {
	description = "CLI local TestSuite alias",
	tests = [("passes", passes)]
}
BRP

cat > "$partial_pass_test" <<'BRP'
import:
    test: TestSuite

func passes() -> Bool:
    True

tests: TestSuite = {
    description = "partial pass",
    tests = [("passes", passes)]
}
BRP

cat > "$partial_timeout_test" <<'BRP'
import:
    channel: sleep
    test: TestSuite

func times_out() -> Bool:
    sleep(3000)
    True

tests: TestSuite = {
    description = "partial timeout",
    tests = [("times out", times_out)]
}
BRP

cat > "$compile_failing_test" <<'BRP'
import:
	test: TestSuite

func test_wrong_return_type() -> Bool:
	1

tests: TestSuite = {
	description = "CLI compile-failing test",
	tests = [("wrong return type", test_wrong_return_type)]
}
BRP

cat > "$timeout_test" <<'BRP'
import:
	test: TestSuite

func test_slow() -> Bool:
	sleep(2000)
	True

tests: TestSuite = {
	description = "CLI timeout test",
	tests = [("slow", test_slow)]
}
BRP

cat > "$repeat_test" <<BRP
import:
	system: append_file
	test: TestSuite

func test_records_run() -> Bool:
	append_file("$repeat_marker", "x\\n")

tests: TestSuite = {
	description = "CLI repeat test",
	tests = [("records run", test_records_run)]
}
BRP

cat > "$signal_helper" <<'SH'
signal_marker="$1"
descendant_marker="$2"
trap '' INT TERM
(
    trap '' INT TERM
    while :; do sleep 1; done
) &
descendant=$!
printf '%s' "$descendant" > "$descendant_marker"
printf started > "$signal_marker"
wait "$descendant"
SH

cat > "$signal_test" <<BRP
import:
	process: run_inherit
	test: TestSuite

func test_waits_for_parent_signal() -> Bool:
	_ = run_inherit(
		"sh",
		["$signal_helper", "$signal_marker", "$signal_descendant_marker"],
	)
	False

tests: TestSuite = {
	description = "CLI signal test",
	tests = [("waits for parent signal", test_waits_for_parent_signal)]
}
BRP

cat > "$child_signal_test" <<'BRP'
import:
	process: run_inherit
	test: TestSuite

func test_terminates_native_process() -> Bool:
	_ = run_inherit("sh", ["-c", "kill -TERM \"$PPID\""])
	sleep(1000)
	False

tests: TestSuite = {
	description = "CLI child signal test",
	tests = [("terminates native process", test_terminates_native_process)]
}
BRP

cat > "$binary_output_test" <<'BRP'
import:
	bytes: bytes
	test: TestSuite

func test_writes_binary_streams() -> Bool:
	output = bytes(3)
		.set_index(0, 0)
		.set_index(1, 65)
		.set_index(2, 255)
	puts(output)
	print_error("candidate-stderr-marker")
	True

tests: TestSuite = {
	description = "CLI binary output test",
	tests = [("writes binary streams", test_writes_binary_streams)]
}
BRP

cat > "$stdin_test" <<'BRP'
import:
	io: read_line
	test: TestSuite

func test_observes_closed_stdin() -> Bool:
	read_line().is_none()

tests: TestSuite = {
	description = "CLI stdin test",
	tests = [("observes closed stdin", test_observes_closed_stdin)]
}
BRP

expect_exit "top-level help" 0 "$BLORP_BIN" --help
expect_exit "top-level version" 0 "$BLORP_BIN" --version
expect_exit "top-level missing command" 1 "$BLORP_BIN"
expect_exit "unknown command" 1 "$BLORP_BIN" does-not-exist

expect_exit "check directory success" 0 "$BLORP_BIN" check --no-format "$check_dir_ok"
expect_exit "check directory failure" 1 "$BLORP_BIN" check --no-format "$check_dir_bad"
expect_output_contains "check empty directory" 1 "no .brp files found" \
    "$BLORP_BIN" check --no-format "$check_dir_empty"
expect_exit "check type failure" 1 "$BLORP_BIN" check --no-format "$invalid_prog"
expect_exit "check missing file arg" 1 "$BLORP_BIN" check
if $run_deep_checks; then
	expect_output_contains "check multi-file success" 0 "Checking " \
		"$BLORP_BIN" check --no-format "$check_dir_ok/root.brp" "$check_dir_ok/nested/child.brp"
	expect_output_contains "check directory dump ast" 0 "Func main" \
		"$BLORP_BIN" check --no-format --dump-ast "$check_dir_ok"
	expect_output_contains "check directory dump typed ast" 0 "Type checking succeeded." \
		"$BLORP_BIN" check --no-format --dump-typed-ast "$check_dir_ok"
fi


if [ "$CLI_MODE" = "all" ]; then
    verify_package_lifecycle
fi

expect_exit "compile success" 0 "$BLORP_BIN" compile --no-format -o "$compiled_c" "$valid_prog"
expect_exit "compile prepared program with invariants" 0 \
	"$BLORP_BIN" compile --check-invariants --no-format \
		-o "$invariant_at_a_glance_c" examples/at_a_glance.brp
expect_exit "compile typed-duration concurrency with invariants" 0 \
	"$BLORP_BIN" compile --check-invariants --no-format \
		-o "$invariant_concurrent_duration_c" \
		blorp/test/compiler/stage_06_typecheck/infer_fixtures/infer/should_pass/concurrent_duration_timeout.brp
expect_exit "internal synthetic executable build uses production compiler" 0 \
	"$BLORP_BIN" __compiler-build-synthetic-executable \
	"$valid_prog" "$valid_prog" "$internal_synthetic_binary"
expect_exit "internal synthetic executable runs" 0 "$internal_synthetic_binary"
expect_exit "compile profile success" 0 \
	"$BLORP_BIN" compile --profile --no-format -o "$profiled_c" "$valid_prog"
TOTAL=$((TOTAL + 1))
if grep -qF 'blorp_profile_start("$blorp$program")' "$profiled_c" \
	&& grep -qF 'atexit(blorp_profile_report)' "$profiled_c"
then
	record_pass "compile profile emits runtime hooks"
else
	record_fail "compile profile emits runtime hooks" \
		"missing function-level profile hooks in $profiled_c"
fi
expect_exit "compile profile window probe" 0 \
	"$BLORP_BIN" compile --profile --no-format -o "$profile_window_c" "$profile_window_prog"
expect_exit "link profile window probe" 0 \
	"${CC:-cc}" -O0 -fwrapv -w "$profile_window_c" -lm -lpthread -o "$profile_window_bin"
TOTAL=$((TOTAL + 1))
run_capture "" "$profile_window_bin"
if [ "$RUN_CODE" -ne 0 ]; then
	record_fail "profile window isolates measured functions" \
		"expected exit 0, got $RUN_CODE
$RUN_OUTPUT"
elif ! grep -qF "profile_window_measured_probe" <<<"$RUN_OUTPUT"; then
	record_fail "profile window isolates measured functions" \
		"measured function is absent from profile output
$RUN_OUTPUT"
elif grep -qF "profile_window_setup_probe" <<<"$RUN_OUTPUT" \
	|| grep -qF "profile_window_after_probe" <<<"$RUN_OUTPUT" \
	|| grep -qF "profile_window_crosses_begin_probe" <<<"$RUN_OUTPUT" \
	|| grep -qF "profile_window_crosses_end_probe" <<<"$RUN_OUTPUT"; then
	record_fail "profile window isolates measured functions" \
		"setup, crossing, or post-window function leaked into profile output
$RUN_OUTPUT"
else
	record_pass "profile window isolates measured functions"
fi
TOTAL=$((TOTAL + 1))
profile_signal_output="$TMPDIR_CLI/profile-window-signal.out"
"$profile_window_bin" wait >"$profile_signal_output" 2>&1 &
profile_signal_pid=$!
CHILD_PIDS+=("$profile_signal_pid")
sleep 0.1
kill -TERM "$profile_signal_pid" 2>/dev/null || true
wait "$profile_signal_pid" 2>/dev/null
profile_signal_code=$?
forget_child_pid "$profile_signal_pid"
if [ "$profile_signal_code" -eq 143 ]; then
	record_pass "profile window preserves SIGTERM delivery after end"
else
	record_fail "profile window preserves SIGTERM delivery after end" \
		"expected exit 143, got $profile_signal_code
$(cat "$profile_signal_output")"
fi
expect_exit "compile succeeds through the production compiler" 0 \
	"$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/direct-compile.c" "$valid_prog"
expect_output_contains "compile AST remains in Blorp frontend" 0 "Func main" \
	"$BLORP_BIN" compile --no-format --ast "$valid_prog"
expect_output_contains "compile stops in Blorp-owned Core tail" 0 "stopped after dce" \
	"$BLORP_BIN" compile --no-format \
		--dump-core-after=dce --dump-core-file="$late_core_dump" \
		--stop-after=dce -o "$late_stopped_c" "$resolved_identity_prog"
TOTAL=$((TOTAL + 1))
if [ -f "$late_core_dump" ] \
	&& grep -qF "===== after dce =====" "$late_core_dump" \
	&& grep -qF '"kind":"program"' "$late_core_dump"; then
	record_pass "compile writes Blorp-owned late Core dump"
else
	record_fail "compile writes Blorp-owned late Core dump" \
		"missing or invalid $late_core_dump"
fi
TOTAL=$((TOTAL + 1))
if [ -f "$late_core_dump" ] && python3 - "$late_core_dump" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as dump_file:
    program = json.loads(next(line for line in dump_file if line.startswith("{")))

target_ids = {
    declaration["def_id"]
    for declaration in program["decls"]
    if declaration.get("kind") == "function"
    and (
        declaration.get("name") == "std_channel__try_send_attempt"
        or declaration.get("name", "").startswith(
            "std_channel__try_send_attempt__mono_"
        )
    )
}
functions_by_id = {
    declaration["def_id"]: declaration
    for declaration in program["decls"]
    if declaration.get("kind") == "function"
}
main = next(
    declaration
    for declaration in functions_by_id.values()
    if declaration.get("name") == "$blorp$program"
)


def calls_retained_target(value, active_ids=frozenset()):
    if isinstance(value, dict):
        call_kind = value.get("call_kind")
        if (
            value.get("kind") == "call"
            and isinstance(call_kind, dict)
            and call_kind.get("def_id") in target_ids
        ):
            return True
        if value.get("kind") == "call" and isinstance(call_kind, dict):
            called_id = call_kind.get("def_id")
            if (
                call_kind.get("kind") == "user"
                and called_id in functions_by_id
                and called_id not in active_ids
                and calls_retained_target(
                    functions_by_id[called_id].get("body"),
                    active_ids | {called_id},
                )
            ):
                return True
        return any(calls_retained_target(child, active_ids) for child in value.values())
    if isinstance(value, list):
        return any(calls_retained_target(child, active_ids) for child in value)
    return False


if not target_ids or not calls_retained_target(main.get("body")):
    raise SystemExit(1)
PY
then
	record_pass "resolved std call and retained declaration share identity"
else
	record_fail "resolved std call and retained declaration share identity" \
		"no resolved call targeted the retained std declaration in $late_core_dump"
fi
TOTAL=$((TOTAL + 1))
if [ ! -e "$late_stopped_c" ]; then
	record_pass "compile late stop skips artifact publication"
else
	record_fail "compile late stop skips artifact publication" \
		"unexpected artifact $late_stopped_c"
fi
if [ -f "$compiled_c" ]; then
    TOTAL=$((TOTAL + 1))
    record_pass "compile writes requested output"
else
    TOTAL=$((TOTAL + 1))
    record_fail "compile writes requested output" "missing $compiled_c"
fi
external_runtime_c="$TMPDIR_CLI/external_runtime.c"
if $run_deep_checks; then
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
fi
expect_exit "compile type failure" 1 "$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/invalid.c" "$invalid_prog"

expect_exit "run success" 0 "$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"
expect_exit "run explicit opaque conversion keywords" 0 \
	"$BLORP_BIN" run --no-format --timeout 5 "$explicit_opaque_prog"
expect_process_inheritance "run_command inherits stdin and output streams" \
	"inherit-input" "inherited-stdout-marker" "inherited-stderr-marker" \
	"${BLORP_DIRECT_TEST_ENV[@]}" "$BLORP_BIN" run --no-format --timeout 15 \
	blorp/test/runtime/sys/process_inheritance_feedback.brp -- blocking
expect_process_inheritance "run_session_command inherits stdin" \
	"session-inherit-input" "" "" \
	"${BLORP_DIRECT_TEST_ENV[@]}" "$BLORP_BIN" run --no-format --timeout 15 \
	blorp/test/runtime/sys/process_inheritance_feedback.brp -- session
expect_output_contains "run reports configured host discovery failure" 1 \
	"host toolchain discovery failed" \
	env CC="$TMPDIR_CLI/missing-cc" \
	"$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"

if $run_deep_checks; then
	expect_output_contains "compile parse failure" 1 'expected `)` after function parameters' \
		"$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/parse_invalid.c" "$parse_invalid_prog"
	expect_exit "run type failure" 1 "$BLORP_BIN" run --no-format --timeout 5 "$invalid_prog"
	expect_output_contains "run parse failure" 1 'expected `)` after function parameters' \
		"$BLORP_BIN" run --no-format --timeout 5 "$parse_invalid_prog"
	expect_exit "run bad timeout" 1 "$BLORP_BIN" run --timeout not-an-int "$valid_prog"
fi

expect_output_excludes "test success omits disabled session counters" 0 \
	"BLORP_TEST_SESSION_COUNTER " \
	"$BLORP_BIN" test --timeout 5 \
	blorp/test/runtime/types/test_bool.brp
expect_exit "test failure" 1 "$BLORP_BIN" test --timeout 5 "$failing_test"
expect_test_session_counters "suite counters are stable across repeat" "[PASS]" 1 1 1 1 1 0 \
	"${BLORP_DIRECT_TEST_ENV[@]}" \
	BLORP_TEST_TIMINGS=1 "$BLORP_BIN" test --suite \
	--repeat 2 --timeout 5 \
	blorp/test/runtime/types/test_bool.brp

	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		"$multi_suite_test_dir"
	if [ "$RUN_CODE" -eq 0 ] \
		&& echo "$RUN_OUTPUT" | grep -qF ">> Bool Tests" \
		&& echo "$RUN_OUTPUT" | grep -qF ">> Char Tests"; then
		record_pass "eligible multiple suites run in one compiler batch"
	else
		record_fail "eligible multiple suites run in one compiler batch" \
			"expected both suite reports with exit 0, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	expect_test_session_counters "same-named suites share one aggregate graph batch" \
		">> format_float builtin Tests" 2 2 1 2 1 0 \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		BLORP_TEST_TIMINGS=1 "$BLORP_BIN" test --suite --timeout 5 \
		blorp/test/runtime/types/test_format_float.brp \
		blorp/test/runtime/text/test_format_float.brp
	TOTAL=$((TOTAL + 1))
	if echo "$RUN_OUTPUT" | grep -qF ">> Float format() Tests" \
		&& echo "$RUN_OUTPUT" | grep -qF ">> format_float builtin Tests"; then
		record_pass "same-named aggregate reports both suites"
	else
		record_fail "same-named aggregate reports both suites" \
			"expected both suite reports from the aggregate run, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		"$failing_test" blorp/test/runtime/types/test_bool.brp
	if [ "$RUN_CODE" -eq 1 ] \
		&& echo "$RUN_OUTPUT" | grep -qF ">> CLI failing test Tests" \
		&& echo "$RUN_OUTPUT" | grep -qF ">> Bool Tests"; then
		record_pass "eligible multi-suite route continues after assertion failure"
	else
		record_fail "eligible multi-suite route continues after assertion failure" \
			"expected both suite reports with exit 1, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --repeat 3 --timeout 5 \
		"$failing_test"
	failing_suite_runs=$(printf '%s\n' "$RUN_OUTPUT" | grep -cF ">> CLI failing test Tests" || true)
	if [ "$RUN_CODE" -eq 1 ] && [ "$failing_suite_runs" -eq 1 ]; then
		record_pass "test repeat stops after a failing iteration"
	else
		record_fail "test repeat stops after a failing iteration" \
			"expected one failing suite run with exit 1, got $failing_suite_runs runs and exit $RUN_CODE
$RUN_OUTPUT"
	fi
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		"$compile_failing_test" blorp/test/runtime/types/test_bool.brp
	if [ "$RUN_CODE" -eq 1 ] \
		&& echo "$RUN_OUTPUT" | grep -qF "returns wrong type" \
		&& ! echo "$RUN_OUTPUT" | grep -qF ">> Bool Tests"; then
		record_pass "eligible multi-suite route stops after compile failure"
	else
		record_fail "eligible multi-suite route stops after compile failure" \
			"expected compile failure without the later suite, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	expect_output_contains "memory suite runs without cwd isolation" 0 \
		">> MemStats Observability" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		blorp/test/runtime/memory/test_memstats_observability.brp
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test "$mixed_test_dir"
	if [ "$RUN_CODE" -eq 0 ] \
		&& echo "$RUN_OUTPUT" | grep -qF ">> Bool Tests" \
		&& echo "$RUN_OUTPUT" | grep -qF ">> Doctests" \
		&& echo "$RUN_OUTPUT" | grep -qF "[PASS] mixed_doctest: runs after its suite" \
		&& echo "$RUN_OUTPUT" | grep -qF \
			"[PASS] documented_value: imports a doctest-only dependency"; then
		record_pass "default mixed TestSuite and doctest directory succeeds"
	else
		record_fail "default mixed TestSuite and doctest directory succeeds" \
			"expected suite and doctest reports with exit 0, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	expect_output_contains "relative std doctest succeeds" 0 \
		">> Doctests" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --doc --timeout 5 std/bytes.brp
	expect_test_session_counters "doctest counters are stable" \
		"[PASS] answer: retains executable doctests" 1 0 0 0 1 0 \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		BLORP_TEST_TIMINGS=1 "$BLORP_BIN" test --doc \
		--timeout 5 "$main_doctest"
	expect_test_session_counters "same-named doctests share one native execution" \
		"[PASS] right_answer: retains the right namespace" 2 0 0 0 1 0 \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		BLORP_TEST_TIMINGS=1 "$BLORP_BIN" test --doc --timeout 5 \
		"$same_stem_doctest_left" "$same_stem_doctest_right"
	TOTAL=$((TOTAL + 1))
	if echo "$RUN_OUTPUT" | grep -qF "[PASS] left_answer: retains the left namespace" \
		&& echo "$RUN_OUTPUT" | grep -qF "[PASS] right_answer: retains the right namespace"; then
		record_pass "same-named doctest aggregate reports both sources"
	else
		record_fail "same-named doctest aggregate reports both sources" \
			"expected both doctest reports from one aggregate run, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	expect_output_contains "wrong-typed tests binding fails semantic typechecking" 1 \
		"expected std/test.TestSuite, got Int" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$wrong_typed_test"
	expect_output_contains "local TestSuite alias is runnable" 0 \
		"[PASS] passes" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$local_alias_test"
	expect_output_contains "empty selected test mode reports no runnable tests" 1 \
		"Error: no runnable tests found" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --doc --timeout 5 \
		blorp/test/runtime/types/test_bool.brp
	expect_output_contains "failing doctest preserves failure status" 1 \
		"[FAIL] documented_failure: reports false" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --doc --timeout 5 "$failing_doctest"
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --doc --timeout 5 "$compile_failing_doctest"
	if [ "$RUN_CODE" -eq 1 ] \
		&& echo "$RUN_OUTPUT" | grep -qF "error:" \
		&& echo "$RUN_OUTPUT" | grep -qF "compile_failing_doctest.brp:6: doctest"; then
		record_pass "compile-failing doctest reports generated-source error"
	else
		record_fail "compile-failing doctest reports generated-source error" \
			"expected a generated-source compile error with exit 1, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	TOTAL=$((TOTAL + 1))
	run_capture "" \
		"${BLORP_DIRECT_TEST_ENV[@]}" BLORP_GATE_RESULT=p1-partial \
		"$BLORP_BIN" test --suite --timeout 1 \
		"$partial_pass_test" "$partial_timeout_test"
	if [ "$RUN_CODE" -eq 1 ] \
		&& echo "$RUN_OUTPUT" | grep -qF "timed out after 2s" \
		&& echo "$RUN_OUTPUT" | grep -qF \
			"BLORP_GATE_RESULT gate=p1-partial status=FAIL passed=1 failed=1 tests=2"; then
		record_pass "combined timeout retains completed source counts"
	else
		record_fail "combined timeout retains completed source counts" \
			"expected one completed pass plus one timeout, got exit $RUN_CODE
$RUN_OUTPUT"
	fi
	expect_output_contains "eligible failing suite preserves status" 1 "[FAIL]" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$failing_test"
	expect_output_contains "eligible compile failure preserves its diagnostic" 1 \
		"returns wrong type" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		"$compile_failing_test"
	expect_output_contains "eligible suite timeout preserves test exit contract" 1 \
		"timed out after 1s" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 1 "$timeout_test"
	expect_output_contains "eligible suite reports native child signal" 1 \
		"exit code 143" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 \
		"$child_signal_test"
	expect_test_binary_streams "eligible suite preserves binary output streams" \
		"${BLORP_DIRECT_TEST_ENV[@]}" BLORP_PROCESS_MAX_OUTPUT_BYTES=4 \
		"$BLORP_BIN" test --suite --timeout 5 "$binary_output_test"
	expect_test_closed_stdout_failure "eligible suite reports output forwarding failure" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$binary_output_test"
	expect_output_contains "eligible suite closes stdin" 0 "[PASS] observes closed stdin" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$stdin_test"
	expect_test_tty_fallback "eligible suite runs with terminal stdin closed" 0 \
		"[PASS] observes closed stdin" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 5 "$stdin_test"
	expect_test_signal_exit "eligible suite handles SIGTERM during host discovery" TERM 143 \
		"$host_discovery_signal_marker" "$host_discovery_descendant_marker" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"CC=sh $signal_helper $host_discovery_signal_marker $host_discovery_descendant_marker" \
		"$BLORP_BIN" test --suite --timeout 5 \
		blorp/test/runtime/types/test_bool.brp
	expect_test_signal_exit "eligible suite handles SIGINT" INT 130 "$signal_marker" \
		"$signal_descendant_marker" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 0 "$signal_test"
	expect_test_signal_exit "eligible suite handles SIGTERM" TERM 143 "$signal_marker" \
		"$signal_descendant_marker" \
		"${BLORP_DIRECT_TEST_ENV[@]}" \
		"$BLORP_BIN" test --suite --timeout 0 "$signal_test"
expect_output_contains "default test mode succeeds" 0 \
	">> Bool Tests" \
	env \
	"$BLORP_BIN" test --timeout 5 \
	blorp/test/runtime/types/test_bool.brp
expect_output_contains "implicit test timeout succeeds" 0 \
	">> Bool Tests" \
	env \
	"$BLORP_BIN" test --suite \
	blorp/test/runtime/types/test_bool.brp
expect_test_environment_stays_blorp_owned BLORP_TEST_TIMEOUT 5
expect_test_environment_stays_blorp_owned BLORP_TIMEOUT 5
expect_test_environment_stays_blorp_owned BLORP_SANITIZE off
expect_test_environment_stays_blorp_owned BLORP_LEAK_CHECK 1
expect_test_environment_stays_blorp_owned BLORP_GATE_RESULT cli-test
expect_test_environment_stays_blorp_owned BLORP_TEST_RETAIN_RUN_ARTIFACTS 1
expect_test_environment_stays_blorp_owned BLORP_TEST_COMPILER_BIN "$TMPDIR_CLI/alternate-compiler"
expect_test_environment_stays_blorp_owned BLORP_TEST_TIMINGS 1
expect_output_contains "Blorp-owned test emits requested gate summary" 0 \
	"BLORP_GATE_RESULT gate=cli-test status=PASS passed=7 failed=0 tests=7" \
	"${BLORP_DIRECT_TEST_ENV[@]}" \
	BLORP_GATE_RESULT=cli-test \
	"$BLORP_BIN" test --suite --timeout 5 \
	blorp/test/runtime/types/test_bool.brp
TOTAL=$((TOTAL + 1))
run_capture "" \
	"${BLORP_DIRECT_TEST_ENV[@]}" \
	BLORP_GATE_RESULT=cli-test \
	"$BLORP_BIN" test --suite --timeout 5 \
	blorp/test/runtime/types/test_bool.brp
if [ "$RUN_CODE" -eq 0 ] \
	&& echo "$RUN_OUTPUT" | grep -Fq \
		'BLORP_TEST_ARTIFACT_START kind=suite sources=1 timeout_seconds=5' \
	&& echo "$RUN_OUTPUT" | grep -Fq \
		'BLORP_TEST_ARTIFACT_SOURCE ' \
	&& echo "$RUN_OUTPUT" | grep -Fq \
		'blorp/test/runtime/types/test_bool.brp' \
	&& echo "$RUN_OUTPUT" | grep -Fq \
		'BLORP_TEST_ARTIFACT_END kind=suite sources=1 duration_ms='
then
	record_pass "Blorp-owned test emits actionable artifact progress"
else
	record_fail "Blorp-owned test emits actionable artifact progress" \
		"expected start, source, and completion records with exit 0, got exit $RUN_CODE
$RUN_OUTPUT"
fi
expect_exit "test warmup succeeds" 0 \
	"$BLORP_BIN" test --warmup-only
expect_output_contains "test warmup requires a populated runtime cache" 1 \
	"test runtime warmup could not populate the runtime cache" \
	env BLORP_RUNTIME_CACHE=/dev/null \
	"$BLORP_BIN" test --warmup-only

if $run_deep_checks; then
	expect_exit "test bad timeout" 1 "$BLORP_BIN" test --timeout not-an-int blorp/test/runtime/types/test_bool.brp
	expect_exit "test bad repeat" 1 "$BLORP_BIN" test --repeat 0 blorp/test/runtime/types/test_bool.brp
	expect_output_contains "test rejects removed no-format option" 1 \
		"unknown test option: --no-format" \
		"$BLORP_BIN" test --no-format --warmup-only
	expect_output_contains "test rejects removed no-cache option" 1 \
		"unknown test option: --no-cache" \
		"$BLORP_BIN" test --no-cache blorp/test/runtime/types/test_bool.brp
	expect_output_contains "test rejects removed jobs option" 1 \
		"unknown test option: -j" \
		"$BLORP_BIN" test -j 1 blorp/test/runtime/types/test_bool.brp
	expect_exit "test warmup only validates later options" 1 "$BLORP_BIN" test --warmup-only --bogus
	rm -f "$repeat_marker"
	expect_exit "test repeat success" 0 "$BLORP_BIN" test --timeout 5 --repeat 3 "$repeat_test"
	TOTAL=$((TOTAL + 1))
	if [ -f "$repeat_marker" ]; then
		repeat_count=$(wc -l < "$repeat_marker" | tr -d ' ')
	else
		repeat_count=0
	fi
	if [ "$repeat_count" = "3" ]; then
		record_pass "test repeat executes requested iterations"
	else
		record_fail "test repeat executes requested iterations" "expected 3 runs, got $repeat_count"
	fi
	expect_output_contains "test honors BLORP_TEST_TIMEOUT" 1 "timed out after 1s" \
		env BLORP_TEST_TIMEOUT=1 "$BLORP_BIN" test "$timeout_test"
fi

expect_exit "format check success" 0 "$BLORP_BIN" format --check "$valid_prog"
expect_exit "format check failure" 1 "$BLORP_BIN" format --check blorp/test/format/should_fail/bad_spacing.brp
expect_exit "format explicit opaque conversions requires bridge rewrite" 1 \
	"$BLORP_BIN" format --check "$explicit_opaque_prog"

TOTAL=$((TOTAL + 1))
cp "$explicit_opaque_prog" "$formatted_opaque_prog"
if "$BLORP_BIN" format "$formatted_opaque_prog" >/dev/null 2>&1 \
	&& grep -Fq 'into UserId(raw)' "$formatted_opaque_prog" \
	&& grep -Fq 'from UserId(value)' "$formatted_opaque_prog" \
	&& ! grep -Fq 'into_opaque' "$formatted_opaque_prog" \
	&& ! grep -Fq 'from_opaque' "$formatted_opaque_prog"; then
	record_pass "format explicit opaque conversions uses bootstrap spelling"
else
	record_fail "format explicit opaque conversions uses bootstrap spelling" \
		"formatter did not canonicalize explicit opaque conversions to the bootstrap spelling"
fi

if $run_deep_checks; then
	expect_exit "format check empty file" 0 "$BLORP_BIN" format --check "$empty_prog"
	expect_exit "format missing file arg" 1 "$BLORP_BIN" format --check
	expect_output_contains "format rejects removed emit JSON option" 1 \
		"unknown format option: --emit-program-json" \
		"$BLORP_BIN" format --check --emit-program-json "$valid_prog"
	expect_output_contains "format diff implies check" 1 "needs formatting" \
		"$BLORP_BIN" format --diff blorp/test/format/should_fail/bad_spacing.brp
fi

expect_exit "purify dry-run success" 0 "$BLORP_BIN" purify --dry-run "$valid_prog"

if $run_deep_checks; then
    formatter_src="$TMPDIR_CLI/formatter_src.brp"
    formatter_expected="$TMPDIR_CLI/formatter_expected.brp"
    formatter_err="$TMPDIR_CLI/formatter.err"
    formatter_tool_c="$TMPDIR_CLI/formatter_tool.c"
    formatter_tool_bin="$TMPDIR_CLI/formatter_tool"
    formatter_tool_ready=false
    : > "$formatter_err"

    cat > "$formatter_src" <<'BRP'
import:
    dict as D
    list: get, append

type alias Pair[A, B] = (A, B)

record Point {x: Int, y: Int}

record Counter {value: Int}

struct Box {value: Int}

union OptionLike[T]:
    SomeLike(T)
    NoneLike

enum Color:
    Red
    Green

trait Incrementable:
    func increment(self: Self) -> Self

trait Named:
    pure func name(self: Self) -> String: "item"

trait Serializable: Incrementable

implements Incrementable for Counter:
    func increment(self: Counter) -> Counter:
        self

private name = "blorp"

foreign:
    func floor(x: Float) -> Float = "c_floor"

---
Read the clock.
---
func read_clock() -> Int:
    builtin("blorp_read_clock")

pure func add(x: Int, y: Int) -> Int:
    x + y

func main(args: List[String]) -> Int:
    print("hi")
    var total: Int = 0
    total += 1
    item ?= maybe_item
    matrix[i, j] = total
    if total > 0:
        total += 1
    else:
        total = 0
    while total < 3:
        total += 1
    for item in items:
        total += item
    match maybe_item:
        Some(x): x
        None: 0
    f = func(x: Int) -> Int: x + 1
    pure func helper[T](x: Int) -> Int:
        x + 1
    message = "total=${total}"
    0
BRP

    TOTAL=$((TOTAL + 1))
    cp "$formatter_src" "$formatter_expected"
    : > "$formatter_err"
    if "$BLORP_BIN" format "$formatter_expected" > "$formatter_err" 2>&1 \
        && "$BLORP_BIN" format --check "$formatter_expected" > "$formatter_err" 2>&1; then
        record_pass "production formatter formats representative program"
    else
        record_fail "production formatter formats representative program" "$(cat "$formatter_err")"
    fi

    TOTAL=$((TOTAL + 1))
    : > "$formatter_err"
    if "$BLORP_BIN" compile --no-format -o "$formatter_tool_c" blorp/src/format/engine/formatter.brp > "$formatter_err" 2>&1 \
        && "${CC:-cc}" -O2 -fwrapv -w "$formatter_tool_c" -lm -lpthread -o "$formatter_tool_bin" >> "$formatter_err" 2>&1; then
        formatter_tool_ready=true
        record_pass "Blorp formatter tool compiles"
    else
        record_fail "Blorp formatter tool compiles" "$(cat "$formatter_err")"
    fi

    expect_formatter_output_contains "Blorp formatter dispatcher help" 0 "Usage: formatter" --help
    expect_formatter_output_contains "Blorp formatter subcommand help" 0 \
        "Usage: formatter program" program --help
    expect_formatter_output_contains "Blorp formatter rejects unknown option" 1 \
        "unknown argument: --bogus" program --bogus "$formatter_src"
    expect_formatter_output_contains "Blorp formatter rejects odd program batch args" 1 \
        "program-batch command requires <program-json-file> <output-file> pairs" \
        program-batch "$formatter_src"
fi

expect_output_contains "lsp help" 0 "Usage: blorp lsp" "$BLORP_BIN" lsp --help
expect_exit "lsp eof shutdown" 0 "$BLORP_BIN" lsp
expect_exit "lsp rejects unknown option" 1 "$BLORP_BIN" lsp --bogus

if $run_deep_checks; then
    verify_stage_two_direct_test_route
fi

finish
