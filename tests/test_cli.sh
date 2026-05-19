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

expect_exit "run success" 0 "$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"
expect_exit "run type failure" 1 "$BLORP_BIN" run --no-format --timeout 5 "$invalid_prog"
expect_exit "run bad timeout" 1 "$BLORP_BIN" run --timeout not-an-int "$valid_prog"

expect_exit "test success" 0 "$BLORP_BIN" test --no-cache --no-format --timeout 5 tests/test_blorp/types/test_bool.brp
expect_exit "test failure" 1 "$BLORP_BIN" test --no-cache --no-format --timeout 5 "$failing_test"
expect_exit "test bad timeout" 1 "$BLORP_BIN" test --timeout not-an-int tests/test_blorp/types/test_bool.brp

expect_exit "format check success" 0 "$BLORP_BIN" format --check "$valid_prog"
expect_exit "format check failure" 1 "$BLORP_BIN" format --check tests/test_compiler/format/should_fail/bad_spacing.brp
expect_exit "format missing file arg" 1 "$BLORP_BIN" format --check

formatter_src="$TMPDIR_CLI/formatter_src.brp"
formatter_expected="$TMPDIR_CLI/formatter_expected.brp"
formatter_doc_json="$TMPDIR_CLI/formatter_doc.json"
formatter_expr_json="$TMPDIR_CLI/formatter_expr.jsonl"
formatter_decl_json="$TMPDIR_CLI/formatter_decl.jsonl"
formatter_actual="$TMPDIR_CLI/formatter_actual.brp"
formatter_err="$TMPDIR_CLI/formatter.err"
formatter_diff="$TMPDIR_CLI/formatter.diff"
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

foreign func floor(x: Float) -> Float = "c_floor"

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
if "$BLORP_BIN" format --emit-doc-json "$formatter_src" > "$formatter_doc_json" 2> "$formatter_err"; then
    if grep -qF '"tag":' "$formatter_doc_json" && grep -qF '"text":"func' "$formatter_doc_json"; then
        record_pass "format emits Doc JSON"
    else
        record_fail "format emits Doc JSON" "Doc JSON was missing expected formatter fields"
    fi
else
    record_fail "format emits Doc JSON" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
: > "$formatter_err"
if "$BLORP_BIN" format --emit-expr-json "$formatter_src" > "$formatter_expr_json" 2> "$formatter_err"; then
    if grep -qF '"expected":' "$formatter_expr_json" && grep -qF '"expr":' "$formatter_expr_json"; then
        record_pass "format emits expression parity JSONL"
    else
        record_fail "format emits expression parity JSONL" "expression parity JSONL was missing expected fields"
    fi
else
    record_fail "format emits expression parity JSONL" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
: > "$formatter_err"
if "$BLORP_BIN" run --no-format --timeout 5 tools/formatter/fmt_expr_main.brp -- "$formatter_expr_json" > "$formatter_err" 2>&1; then
    record_pass "Blorp expression formatter matches OCaml expression cases"
else
    record_fail "Blorp expression formatter matches OCaml expression cases" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
: > "$formatter_err"
if "$BLORP_BIN" format --emit-decl-json "$formatter_src" > "$formatter_decl_json" 2> "$formatter_err"; then
    if grep -qF '"expected":' "$formatter_decl_json" && grep -qF '"decl":' "$formatter_decl_json"; then
        record_pass "format emits declaration parity JSONL"
    else
        record_fail "format emits declaration parity JSONL" "declaration parity JSONL was missing expected fields"
    fi
else
    record_fail "format emits declaration parity JSONL" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
: > "$formatter_err"
if "$BLORP_BIN" run --no-format --timeout 5 tools/formatter/fmt_decl_main.brp -- "$formatter_decl_json" > "$formatter_err" 2>&1; then
    record_pass "Blorp declaration formatter matches OCaml declaration cases"
else
    record_fail "Blorp declaration formatter matches OCaml declaration cases" "$(cat "$formatter_err")"
fi

TOTAL=$((TOTAL + 1))
cp "$formatter_src" "$formatter_expected"
: > "$formatter_err"
: > "$formatter_diff"
if "$BLORP_BIN" format "$formatter_expected" > "$formatter_err" 2>&1 \
    && "$BLORP_BIN" run --no-format --timeout 5 tools/formatter/fmt_layout_main.brp -- "$formatter_doc_json" > "$formatter_actual" 2> "$formatter_err" \
    && diff -u "$formatter_expected" "$formatter_actual" > "$formatter_diff"; then
    record_pass "Blorp formatter layout matches OCaml layout"
else
    record_fail "Blorp formatter layout matches OCaml layout" "$(cat "$formatter_err"; cat "$formatter_diff")"
fi

formatter_corpus_expected_dir="$TMPDIR_CLI/formatter_corpus_expected"
formatter_corpus_actual_dir="$TMPDIR_CLI/formatter_corpus_actual"
formatter_corpus_json_dir="$TMPDIR_CLI/formatter_corpus_json"
formatter_corpus_err="$TMPDIR_CLI/formatter_corpus.err"
formatter_corpus_diff="$TMPDIR_CLI/formatter_corpus.diff"
mkdir -p "$formatter_corpus_expected_dir" "$formatter_corpus_actual_dir" "$formatter_corpus_json_dir"

formatter_batch_args=("--batch")
formatter_batch_expected=()
formatter_batch_actual=()
formatter_batch_names=()

prepare_formatter_corpus_case() {
    local source="$1"
    local base expected doc_json actual err

    base="$(basename "$source")"
    expected="$formatter_corpus_expected_dir/$base"
    doc_json="$formatter_corpus_json_dir/$base.json"
    actual="$formatter_corpus_actual_dir/$base"
    err="$TMPDIR_CLI/formatter_corpus_$base.err"
    : > "$err"

    if cp "$source" "$expected" \
        && "$BLORP_BIN" format --emit-doc-json "$source" > "$doc_json" 2> "$err"; then
        formatter_batch_args+=("$doc_json" "$actual")
        formatter_batch_expected+=("$expected")
        formatter_batch_actual+=("$actual")
        formatter_batch_names+=("formatter corpus $base")
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

formatter_batch_ok=false
if $formatter_expected_ok && [ ${#formatter_batch_expected[@]} -gt 0 ]; then
    TOTAL=$((TOTAL + 1))
    : > "$formatter_corpus_err"
    if "$BLORP_BIN" run --no-format --timeout 5 tools/formatter/fmt_layout_main.brp -- "${formatter_batch_args[@]}" > "$formatter_corpus_err" 2>&1; then
        formatter_batch_ok=true
        record_pass "formatter corpus batch renders"
    else
        record_fail "formatter corpus batch renders" "$(cat "$formatter_corpus_err")"
    fi
fi

if $formatter_batch_ok; then
    for idx in "${!formatter_batch_expected[@]}"; do
        TOTAL=$((TOTAL + 1))
        : > "$formatter_corpus_diff"
        if diff -u "${formatter_batch_expected[$idx]}" "${formatter_batch_actual[$idx]}" > "$formatter_corpus_diff"; then
            record_pass "${formatter_batch_names[$idx]}"
        else
            record_fail "${formatter_batch_names[$idx]}" "$(cat "$formatter_corpus_diff")"
        fi
    done
fi

std_layout_expected_dir="$TMPDIR_CLI/std_layout_expected"
std_layout_actual_dir="$TMPDIR_CLI/std_layout_actual"
std_layout_json_dir="$TMPDIR_CLI/std_layout_json"
std_layout_err="$TMPDIR_CLI/std_layout.err"
std_layout_diff="$TMPDIR_CLI/std_layout.diff"
mkdir -p "$std_layout_expected_dir" "$std_layout_actual_dir" "$std_layout_json_dir"

TOTAL=$((TOTAL + 1))
std_layout_ok=true
std_layout_msg=""
std_batch_args=("--batch")
if ! cp -R std "$std_layout_expected_dir/std" > "$std_layout_err" 2>&1; then
    std_layout_ok=false
    std_layout_msg="$(cat "$std_layout_err")"
fi
if $std_layout_ok && ! "$BLORP_BIN" format "$std_layout_expected_dir/std" > "$std_layout_err" 2>&1; then
    std_layout_ok=false
    std_layout_msg="$(cat "$std_layout_err")"
fi
if $std_layout_ok; then
    while IFS= read -r std_source; do
        std_rel="${std_source#std/}"
        std_doc_json="$std_layout_json_dir/${std_rel%.brp}.json"
        std_actual="$std_layout_actual_dir/std/$std_rel"
        mkdir -p "$(dirname "$std_doc_json")" "$(dirname "$std_actual")"
        if "$BLORP_BIN" format --emit-doc-json "$std_source" > "$std_doc_json" 2> "$std_layout_err"; then
            std_batch_args+=("$std_doc_json" "$std_actual")
        else
            std_layout_ok=false
            std_layout_msg="$(cat "$std_layout_err")"
            break
        fi
    done < <(find std -name '*.brp' | sort)
fi
if $std_layout_ok && ! "$BLORP_BIN" run --no-format --timeout "$CLI_TIMEOUT" tools/formatter/fmt_layout_main.brp -- "${std_batch_args[@]}" > "$std_layout_err" 2>&1; then
    std_layout_ok=false
    std_layout_msg="$(cat "$std_layout_err")"
fi
if $std_layout_ok; then
    while IFS= read -r std_source; do
        std_rel="${std_source#std/}"
        if ! diff -u "$std_layout_expected_dir/std/$std_rel" "$std_layout_actual_dir/std/$std_rel" > "$std_layout_diff"; then
            std_layout_ok=false
            std_layout_msg="$(cat "$std_layout_diff")"
            break
        fi
    done < <(find std -name '*.brp' | sort)
fi
if $std_layout_ok; then
    record_pass "std formatter layout batch matches OCaml layout"
else
    record_fail "std formatter layout batch matches OCaml layout" "$std_layout_msg"
fi

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
