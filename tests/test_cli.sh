#!/usr/bin/env bash
# Public CLI smoke and exit-code contract tests.

set -u

cd "$(dirname "$0")/.."

BLORP_BIN="${BLORP_BIN:-./blorp}"
# Cold self-hosted formatter startup may need to compile the embedded Blorp
# formatter before the format checks can run.
CLI_TIMEOUT="${BLORP_CLI_TEST_TIMEOUT:-${BLORP_TEST_TIMEOUT:-60}}"
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

valid_prog="$TMPDIR_CLI/valid.brp"
empty_prog="$TMPDIR_CLI/empty.brp"
invalid_prog="$TMPDIR_CLI/invalid.brp"
failing_test="$TMPDIR_CLI/failing_test.brp"
timeout_test="$TMPDIR_CLI/timeout_test.brp"
repeat_test="$TMPDIR_CLI/repeat_test.brp"
repeat_marker="$TMPDIR_CLI/repeat_marker.txt"
compiled_c="$TMPDIR_CLI/valid.c"
check_dir_ok="$TMPDIR_CLI/check_dir_ok"
check_dir_bad="$TMPDIR_CLI/check_dir_bad"

mkdir -p "$check_dir_ok/nested" "$check_dir_bad/nested"

cat > "$valid_prog" <<'BRP'
func main(args: List[String]) -> Int:
	print("cli ok")
	0
BRP
: > "$empty_prog"

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

expect_exit "run success" 0 "$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"
expect_exit "run type failure" 1 "$BLORP_BIN" run --no-format --timeout 5 "$invalid_prog"
expect_exit "run bad timeout" 1 "$BLORP_BIN" run --timeout not-an-int "$valid_prog"

expect_exit "test success" 0 "$BLORP_BIN" test --no-cache --no-format --timeout 5 tests/test_blorp/types/test_bool.brp
expect_exit "test failure" 1 "$BLORP_BIN" test --no-cache --no-format --timeout 5 "$failing_test"
expect_exit "test bad timeout" 1 "$BLORP_BIN" test --timeout not-an-int tests/test_blorp/types/test_bool.brp
expect_exit "test bad repeat" 1 "$BLORP_BIN" test --repeat 0 tests/test_blorp/types/test_bool.brp
rm -f "$repeat_marker"
expect_exit "test repeat success" 0 "$BLORP_BIN" test --no-format --timeout 5 --repeat 3 "$repeat_test"
TOTAL=$((TOTAL + 1))
if [ -f "$repeat_marker" ]; then
    repeat_count=$(wc -l < "$repeat_marker" | tr -d ' ')
else
    repeat_count=0
fi
if [ "$repeat_count" = "3" ]; then
    record_pass "test repeat disables result cache"
else
    record_fail "test repeat disables result cache" "expected 3 runs, got $repeat_count"
fi
expect_output_contains "test honors BLORP_TEST_TIMEOUT" 1 "timed out after 1s" \
    env BLORP_TEST_TIMEOUT=1 "$BLORP_BIN" test --no-cache --no-format "$timeout_test"

expect_exit "format check success" 0 "$BLORP_BIN" format --check "$valid_prog"
expect_exit "format check empty file" 0 "$BLORP_BIN" format --check "$empty_prog"
expect_exit "format check failure" 1 "$BLORP_BIN" format --check tests/test_compiler/format/should_fail/bad_spacing.brp
expect_exit "format missing file arg" 1 "$BLORP_BIN" format --check
expect_output_contains "format rejects removed expression JSON flag" 1 "unknown format option: --emit-expr-json" \
    "$BLORP_BIN" format --emit-expr-json "$valid_prog"
expect_output_contains "format rejects removed Doc JSON flag" 1 "unknown format option: --emit-doc-json" \
    "$BLORP_BIN" format --emit-doc-json "$valid_prog"
expect_output_contains "format rejects emit JSON with check" 1 "cannot be combined" \
    "$BLORP_BIN" format --check --emit-program-json "$valid_prog"
expect_output_contains "format diff implies check" 1 "needs formatting" \
    "$BLORP_BIN" format --diff tests/test_compiler/format/should_fail/bad_spacing.brp

formatter_src="$TMPDIR_CLI/formatter_src.brp"
formatter_expected="$TMPDIR_CLI/formatter_expected.brp"
formatter_program_json="$TMPDIR_CLI/formatter_program.json"
formatter_actual="$TMPDIR_CLI/formatter_actual.brp"
formatter_err="$TMPDIR_CLI/formatter.err"
formatter_diff="$TMPDIR_CLI/formatter.diff"
formatter_tool_c="$TMPDIR_CLI/formatter_tool.c"
formatter_tool_bin="$TMPDIR_CLI/formatter_tool"
formatter_tool_ready=false
: > "$formatter_err"
: > "$formatter_diff"

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
: > "$formatter_err"
if "$BLORP_BIN" format --emit-program-json "$formatter_src" > "$formatter_program_json" 2> "$formatter_err"; then
    if grep -qF '"comments":' "$formatter_program_json" && grep -qF '"program":' "$formatter_program_json"; then
        record_pass "format emits full-program formatter JSON"
    else
        record_fail "format emits full-program formatter JSON" "program JSON was missing expected fields"
    fi
else
    record_fail "format emits full-program formatter JSON" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
: > "$formatter_err"
if "$BLORP_BIN" compile --no-format -o "$formatter_tool_c" tools/formatter/formatter.brp > "$formatter_err" 2>&1 \
    && "${CC:-cc}" -O2 -fwrapv -w "$formatter_tool_c" -lm -lpthread -o "$formatter_tool_bin" >> "$formatter_err" 2>&1; then
    formatter_tool_ready=true
    record_pass "Blorp formatter tool compiles"
else
    record_fail "Blorp formatter tool compiles" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
cp "$formatter_src" "$formatter_expected"
: > "$formatter_err"
: > "$formatter_diff"
if $formatter_tool_ready \
    && "$BLORP_BIN" format "$formatter_expected" > "$formatter_err" 2>&1 \
    && "$formatter_tool_bin" program "$formatter_program_json" > "$formatter_actual" 2> "$formatter_err" \
    && diff -u "$formatter_expected" "$formatter_actual" > "$formatter_diff"; then
    record_pass "Blorp program formatter matches production formatter"
else
    record_fail "Blorp program formatter matches production formatter" "$(cat "$formatter_err"; cat "$formatter_diff")"
fi
expect_formatter_output_contains "Blorp formatter dispatcher help" 0 "Usage: formatter" --help
expect_formatter_output_contains "Blorp formatter subcommand help" 0 \
    "Usage: formatter program" program --help
expect_formatter_output_contains "Blorp formatter rejects unknown option" 1 \
    "unknown argument: --bogus" program --bogus "$formatter_program_json"
expect_formatter_output_contains "Blorp formatter rejects odd program batch args" 1 \
    "program-batch command requires <program-json-file> <output-file> pairs" \
    program-batch "$formatter_program_json"
expect_formatter_output_contains "Blorp formatter rejects removed document command" 1 \
    "unknown formatter command: document" document --help

formatter_corpus_expected_dir="$TMPDIR_CLI/formatter_corpus_expected"
formatter_corpus_actual_dir="$TMPDIR_CLI/formatter_corpus_actual"
formatter_corpus_json_dir="$TMPDIR_CLI/formatter_corpus_json"
formatter_corpus_err="$TMPDIR_CLI/formatter_corpus.err"
formatter_corpus_diff="$TMPDIR_CLI/formatter_corpus.diff"
mkdir -p "$formatter_corpus_expected_dir" "$formatter_corpus_actual_dir" "$formatter_corpus_json_dir"

formatter_program_batch_args=("program-batch")
formatter_program_expected=()
formatter_program_actual=()

prepare_formatter_corpus_case() {
    local source="$1"
    local base expected program_json program_actual err

    base="$(basename "$source")"
    expected="$formatter_corpus_expected_dir/$base"
    program_json="$formatter_corpus_json_dir/$base.program.json"
    program_actual="$formatter_corpus_actual_dir/program/$base"
    err="$TMPDIR_CLI/formatter_corpus_$base.err"
    mkdir -p "$(dirname "$program_actual")"
    : > "$err"

    if cp "$source" "$expected" \
        && "$BLORP_BIN" format --emit-program-json "$source" > "$program_json" 2> "$err"; then
        formatter_program_batch_args+=("$program_json" "$program_actual")
        formatter_program_expected+=("$expected")
        formatter_program_actual+=("$program_actual")
    else
        TOTAL=$((TOTAL + 1))
        record_fail "formatter corpus $base" "$(cat "$err")"
    fi
}

for formatter_case in tests/test_compiler/format/should_pass/*.brp; do
    prepare_formatter_corpus_case "$formatter_case"
done

formatter_expected_ok=false
TOTAL=$((TOTAL + 1))
: > "$formatter_corpus_err"
if "$BLORP_BIN" format "$formatter_corpus_expected_dir" > "$formatter_corpus_err" 2>&1; then
    formatter_expected_ok=true
    record_pass "formatter corpus expected files format"
else
    record_fail "formatter corpus expected files format" "$(cat "$formatter_corpus_err")"
fi

formatter_program_batch_ok=false
if $formatter_expected_ok && [ ${#formatter_program_expected[@]} -gt 0 ]; then
    TOTAL=$((TOTAL + 1))
    : > "$formatter_corpus_err"
    if ! $formatter_tool_ready; then
        record_fail "formatter corpus program batch renders" "formatter tool did not compile"
    elif "$formatter_tool_bin" "${formatter_program_batch_args[@]}" > "$formatter_corpus_err" 2>&1; then
        formatter_program_batch_ok=true
        record_pass "formatter corpus program batch renders"
    else
        record_fail "formatter corpus program batch renders" "$(cat "$formatter_corpus_err")"
    fi
fi

if $formatter_program_batch_ok; then
    TOTAL=$((TOTAL + 1))
    formatter_program_msg=""
    for idx in "${!formatter_program_expected[@]}"; do
        : > "$formatter_corpus_diff"
        if ! diff -u "${formatter_program_expected[$idx]}" "${formatter_program_actual[$idx]}" > "$formatter_corpus_diff"; then
            formatter_program_msg="$(cat "$formatter_corpus_diff")"
            break
        fi
    done
    if [ -z "$formatter_program_msg" ]; then
        record_pass "formatter corpus program batch matches production formatter"
    else
        record_fail "formatter corpus program batch matches production formatter" "$formatter_program_msg"
    fi
fi

formatter_self_expected_dir="$TMPDIR_CLI/formatter_self_expected"
formatter_self_actual_dir="$TMPDIR_CLI/formatter_self_actual"
formatter_self_json_dir="$TMPDIR_CLI/formatter_self_json"
formatter_self_err="$TMPDIR_CLI/formatter_self.err"
formatter_self_diff="$TMPDIR_CLI/formatter_self.diff"
mkdir -p "$formatter_self_expected_dir" "$formatter_self_actual_dir" "$formatter_self_json_dir"

TOTAL=$((TOTAL + 1))
formatter_self_ok=true
formatter_self_msg=""
formatter_self_batch_args=("program-batch")
if ! cp -R tools/formatter "$formatter_self_expected_dir/formatter" > "$formatter_self_err" 2>&1; then
    formatter_self_ok=false
    formatter_self_msg="$(cat "$formatter_self_err")"
fi
if $formatter_self_ok && ! "$BLORP_BIN" format "$formatter_self_expected_dir/formatter" > "$formatter_self_err" 2>&1; then
    formatter_self_ok=false
    formatter_self_msg="$(cat "$formatter_self_err")"
fi
if $formatter_self_ok; then
    while IFS= read -r formatter_source; do
        formatter_rel="${formatter_source#tools/formatter/}"
        formatter_program_json="$formatter_self_json_dir/${formatter_rel%.brp}.json"
        formatter_actual="$formatter_self_actual_dir/formatter/$formatter_rel"
        mkdir -p "$(dirname "$formatter_program_json")" "$(dirname "$formatter_actual")"
        if "$BLORP_BIN" format --emit-program-json "$formatter_source" > "$formatter_program_json" 2> "$formatter_self_err"; then
            formatter_self_batch_args+=("$formatter_program_json" "$formatter_actual")
        else
            formatter_self_ok=false
            formatter_self_msg="$(cat "$formatter_self_err")"
            break
        fi
    done < <(find tools/formatter -name '*.brp' | sort)
fi
if $formatter_self_ok && ! $formatter_tool_ready; then
    formatter_self_ok=false
    formatter_self_msg="formatter tool did not compile"
fi
if $formatter_self_ok && ! "$formatter_tool_bin" "${formatter_self_batch_args[@]}" > "$formatter_self_err" 2>&1; then
    formatter_self_ok=false
    formatter_self_msg="$(cat "$formatter_self_err")"
fi
if $formatter_self_ok; then
    while IFS= read -r formatter_expected; do
        formatter_rel="${formatter_expected#$formatter_self_expected_dir/formatter/}"
        if ! diff -u "$formatter_expected" "$formatter_self_actual_dir/formatter/$formatter_rel" > "$formatter_self_diff"; then
            formatter_self_ok=false
            formatter_self_msg="$(cat "$formatter_self_diff")"
            break
        fi
    done < <(find "$formatter_self_expected_dir/formatter" -name '*.brp' | sort)
fi
if $formatter_self_ok; then
    record_pass "formatter sources program batch matches production formatter"
else
    record_fail "formatter sources program batch matches production formatter" "$formatter_self_msg"
fi

std_expected_dir="$TMPDIR_CLI/std_expected"
std_actual_dir="$TMPDIR_CLI/std_actual"
std_json_dir="$TMPDIR_CLI/std_json"
std_err="$TMPDIR_CLI/std.err"
std_diff="$TMPDIR_CLI/std.diff"
mkdir -p "$std_expected_dir" "$std_actual_dir" "$std_json_dir"

TOTAL=$((TOTAL + 1))
std_ok=true
std_msg=""
std_batch_args=("program-batch")
if ! cp -R std "$std_expected_dir/std" > "$std_err" 2>&1; then
    std_ok=false
    std_msg="$(cat "$std_err")"
fi
if $std_ok && ! "$BLORP_BIN" format "$std_expected_dir/std" > "$std_err" 2>&1; then
    std_ok=false
    std_msg="$(cat "$std_err")"
fi
if $std_ok; then
    while IFS= read -r std_source; do
        std_rel="${std_source#std/}"
        std_json="$std_json_dir/${std_rel%.brp}.json"
        std_actual="$std_actual_dir/std/$std_rel"
        mkdir -p "$(dirname "$std_json")" "$(dirname "$std_actual")"
        if "$BLORP_BIN" format --emit-program-json "$std_source" > "$std_json" 2> "$std_err"; then
            std_batch_args+=("$std_json" "$std_actual")
        else
            std_ok=false
            std_msg="$(cat "$std_err")"
            break
        fi
    done < <(find std -name '*.brp' | sort)
fi
if $std_ok && ! $formatter_tool_ready; then
    std_ok=false
    std_msg="formatter tool did not compile"
fi
if $std_ok && ! "$formatter_tool_bin" "${std_batch_args[@]}" > "$std_err" 2>&1; then
    std_ok=false
    std_msg="$(cat "$std_err")"
fi
if $std_ok; then
    while IFS= read -r std_source; do
        std_rel="${std_source#std/}"
        if ! diff -u "$std_expected_dir/std/$std_rel" "$std_actual_dir/std/$std_rel" > "$std_diff"; then
            std_ok=false
            std_msg="$(cat "$std_diff")"
            break
        fi
    done < <(find std -name '*.brp' | sort)
fi
if $std_ok; then
    record_pass "std formatter program batch matches production formatter"
else
    record_fail "std formatter program batch matches production formatter" "$std_msg"
fi

expect_output_contains "repl help" 0 "Usage: blorp repl" "$BLORP_BIN" repl --help
expect_stdin_exit "repl quit" 0 ":quit
" "$BLORP_BIN" repl
expect_exit "repl rejects unknown option" 1 "$BLORP_BIN" repl --bogus

expect_output_contains "lsp help" 0 "Usage: blorp lsp" "$BLORP_BIN" lsp --help
expect_exit "lsp eof shutdown" 0 "$BLORP_BIN" lsp
expect_exit "lsp rejects unknown option" 1 "$BLORP_BIN" lsp --bogus
expect_output_contains "lsp integration smoke" 0 "0 failed" \
    tests/test_lsp.sh "$BLORP_BIN"

echo ""
echo "Results: $PASS passed, $FAIL failed ($TOTAL CLI checks)"
if [ "$FAIL" -gt 0 ]; then
    echo "BLORP_GATE_RESULT gate=cli status=FAIL passed=$PASS failed=$FAIL tests=$TOTAL"
else
    echo "BLORP_GATE_RESULT gate=cli status=PASS passed=$PASS failed=0 tests=$TOTAL"
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
