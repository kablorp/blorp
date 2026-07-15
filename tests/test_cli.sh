#!/usr/bin/env bash
# Public CLI smoke and exit-code contract tests.

set -u

cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: tests/test_cli.sh [--all|--smoke] [--timeout SECONDS] [--gate-name NAME]

Options:
  --all                Run the full CLI integration set, including package lifecycle and formatter tool checks.
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

BLORP_BIN="${BLORP_BIN:-./blorp}"
if [[ "$BLORP_BIN" = /* ]]; then
    BLORP_BIN_ABS="$BLORP_BIN"
else
    BLORP_BIN_ABS="$PWD/${BLORP_BIN#./}"
fi
# Smoke mode is the default local-loop shape used by scripts/test. The full
# mode keeps package cache/vendor workflows and self-hosted formatter checks
# available for premerge, where broader process/compiler integration is useful
# enough to justify the extra work.
run_deep_checks=true
if [ "$CLI_MODE" = "smoke" ]; then
    run_deep_checks=false
fi
TMPDIR_CLI=$(mktemp -d "${TMPDIR:-/tmp}/blorp_cli.XXXXXX") || exit 1
PASS=0
FAIL=0
TOTAL=0
RUN_OUTPUT=""
RUN_CODE=0
CHILD_PIDS=()

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
parse_invalid_prog="$TMPDIR_CLI/parse_invalid.brp"
failing_test="$TMPDIR_CLI/failing_test.brp"
timeout_test="$TMPDIR_CLI/timeout_test.brp"
repeat_test="$TMPDIR_CLI/repeat_test.brp"
repeat_marker="$TMPDIR_CLI/repeat_marker.txt"
compiled_c="$TMPDIR_CLI/valid.c"
late_core_dump="$TMPDIR_CLI/late-core.dump"
late_stopped_c="$TMPDIR_CLI/late-stopped.c"
check_dir_ok="$TMPDIR_CLI/check_dir_ok"
check_dir_bad="$TMPDIR_CLI/check_dir_bad"
check_dir_empty="$TMPDIR_CLI/check_dir_empty"
package_ok="$TMPDIR_CLI/package_ok"
package_bad="$TMPDIR_CLI/package_bad"
package_project="$TMPDIR_CLI/package_project"
package_alias_project="$TMPDIR_CLI/package_alias_project"
package_cache_project="$TMPDIR_CLI/package_cache_project"
package_cache_alias_project="$TMPDIR_CLI/package_cache_alias_project"
package_ambiguous_project="$TMPDIR_CLI/package_ambiguous_project"
package_vendor_all_project="$TMPDIR_CLI/package_vendor_all_project"
package_cache="$TMPDIR_CLI/package_cache"
package_alias_cache="$TMPDIR_CLI/package_alias_cache"
package_fetch_all_cache="$TMPDIR_CLI/package_fetch_all_cache"
package_missing_cache="$TMPDIR_CLI/package_missing_cache"
package_artifact="$TMPDIR_CLI/sample.blorpkg"
package_vendor="$TMPDIR_CLI/vendor_sample"

mkdir -p "$check_dir_ok/nested" "$check_dir_bad/nested" "$check_dir_empty"
mkdir -p "$package_ok/src/sample" "$package_bad/src"
mkdir -p "$package_project/app" "$package_project/vendor"
mkdir -p "$package_alias_project/app" "$package_alias_project/vendor"
mkdir -p "$package_cache_project/app" "$package_cache_alias_project/app"
mkdir -p "$package_ambiguous_project" "$package_vendor_all_project"
mkdir -p "$package_cache" "$package_alias_cache" "$package_fetch_all_cache"
mkdir -p "$package_missing_cache"

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

cat > "$parse_invalid_prog" <<'BRP'
func bad(
BRP

cp "$valid_prog" "$check_dir_ok/root.brp"
cp "$valid_prog" "$check_dir_ok/nested/child.brp"
cp "$valid_prog" "$check_dir_bad/root.brp"
cp "$invalid_prog" "$check_dir_bad/nested/child.brp"

cat > "$package_ok/package.toml" <<'TOML'
[package]
name = "sample"

[compat]
std = "preview-1"

[exports]
modules = ["sample", "sample/internal"]
TOML

cat > "$package_ok/src/sample.brp" <<'BRP'
import:
	sample/internal as Internal

pure func answer() -> Int:
	Internal.answer()
BRP

cat > "$package_ok/src/sample/internal.brp" <<'BRP'
pure func answer() -> Int:
	42
BRP

cat > "$package_bad/package.toml" <<'TOML'
[package]
name = "sample"

[compat]
std = "preview-1"

[exports]
modules = ["sample"]
TOML

cat > "$package_bad/src/sample.brp" <<'BRP'
import:
	local_helper

pure func answer() -> Int:
	0
BRP

cp -R "$package_ok" "$package_project/vendor/sample"
cat > "$package_project/blorp.toml" <<'TOML'
[packages]
sample = { path = "vendor/sample" }
TOML

cp -R "$package_ok" "$package_alias_project/vendor/sample"
cat > "$package_alias_project/blorp.toml" <<'TOML'
[packages]
sample_v1 = { path = "vendor/sample" }
TOML

cat > "$package_project/app/main.brp" <<'BRP'
import:
	sample: answer

func main(args: List[String]) -> Int:
	answer()
BRP

cat > "$package_alias_project/app/main.brp" <<'BRP'
import:
	sample_v1: answer

func main(args: List[String]) -> Int:
	answer()
BRP

cat > "$package_cache_project/app/main.brp" <<'BRP'
import:
	sample: answer

func main(args: List[String]) -> Int:
	answer()
BRP

cat > "$package_cache_alias_project/app/main.brp" <<'BRP'
import:
	sample_v1: answer

func main(args: List[String]) -> Int:
	answer()
BRP

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

expect_exit "check bypasses OCaml host" 0 \
    env BLORP_OCAML_HOST_BIN="$TMPDIR_CLI/missing-ocaml-host" \
    "$BLORP_BIN" check --no-format "$valid_prog"
expect_exit "check directory success" 0 "$BLORP_BIN" check --no-format "$check_dir_ok"
expect_exit "check directory failure" 1 "$BLORP_BIN" check --no-format "$check_dir_bad"
expect_output_contains "check empty directory" 1 "no .brp files found" \
    "$BLORP_BIN" check --no-format "$check_dir_empty"
expect_exit "check type failure" 1 "$BLORP_BIN" check --no-format "$invalid_prog"
expect_exit "check missing file arg" 1 "$BLORP_BIN" check
expect_output_contains "package help" 0 "Usage: blorp package" \
    "$BLORP_BIN" package --help
expect_output_contains "package check success" 0 "Package sample: ok" \
    "$BLORP_BIN" package check "$package_ok"
expect_output_contains "package check rejects external import" 1 "may import only std modules" \
    "$BLORP_BIN" package check "$package_bad"

if $run_deep_checks; then
	expect_output_contains "check multi-file success" 0 "Checking " \
		"$BLORP_BIN" check --no-format "$check_dir_ok/root.brp" "$check_dir_ok/nested/child.brp"
	expect_output_contains "check directory dump ast" 0 "Func main" \
		"$BLORP_BIN" check --no-format --dump-ast "$check_dir_ok"
	expect_output_contains "check directory dump typed ast" 0 "Type checking succeeded." \
		"$BLORP_BIN" check --no-format --dump-typed-ast "$check_dir_ok"

    TOTAL=$((TOTAL + 1))
    if run_capture "" "$BLORP_BIN" package hash "$package_ok" \
        && [[ "$RUN_OUTPUT" =~ ^[0-9a-f]{64}$ ]]; then
        record_pass "package hash success"
        package_hash="$RUN_OUTPUT"
    else
        record_fail "package hash success" \
            "expected 64 lowercase hex characters, got: $RUN_OUTPUT"
        package_hash=""
    fi
    if [ -n "$package_hash" ]; then
        expect_output_contains "package pack success" 0 "Hash $package_hash" \
            "$BLORP_BIN" package pack "$package_ok" -o "$package_artifact"
        cat > "$package_cache_project/blorp.toml" <<TOML
[packages]
sample = { hash = "${package_hash:0:16}", from = ["../sample.blorpkg"] }
TOML
        cat > "$package_cache_alias_project/blorp.toml" <<TOML
[packages]
sample_v1 = { hash = "${package_hash:0:16}", from = ["../sample.blorpkg"] }
TOML
        expect_output_contains "package fetch success" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_cache" "$BLORP_BIN" package fetch "$package_hash" "$package_artifact"
        expect_output_contains "package fetch explicit uses cache" 0 "Already cached sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" "$BLORP_BIN" package fetch "$package_hash" "$package_artifact"
        expect_output_contains "package fetch alias uses cache" 0 "Already cached sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package fetch sample' bash "$package_cache_project" "$BLORP_BIN_ABS"
        expect_output_contains "package fetch renamed alias success" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_alias_cache" bash -c 'cd "$1" && "$2" package fetch sample_v1' bash "$package_cache_alias_project" "$BLORP_BIN_ABS"
        expect_output_contains "check cached package alias missing cache suggests fetch" 1 "blorp package fetch sample" \
            env BLORP_PACKAGE_CACHE="$package_missing_cache" "$BLORP_BIN" check --no-format "$package_cache_project/app/main.brp"
        expect_output_contains "package fetch all success" 0 "Fetched sample" \
            env BLORP_PACKAGE_CACHE="$package_fetch_all_cache" bash -c 'cd "$1" && "$2" package fetch' bash "$package_cache_project" "$BLORP_BIN_ABS"
        cat > "$package_ambiguous_project/blorp.toml" <<TOML
[packages]
sample_a = { hash = "${package_hash:0:16}", from = ["../sample.blorpkg"] }
sample_b = { hash = "${package_hash:0:16}", from = ["../sample.blorpkg"] }
TOML
        cat > "$package_vendor_all_project/blorp.toml" <<TOML
[packages]
sample = { hash = "${package_hash:0:16}", from = ["../sample.blorpkg"] }
TOML
        expect_output_contains "package vendor all success" 0 "Vendored sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package vendor' bash "$package_vendor_all_project" "$BLORP_BIN_ABS"
        expect_output_contains "package vendor all idempotent" 0 "Already vendored sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package vendor' bash "$package_vendor_all_project" "$BLORP_BIN_ABS"
        if [ -f "$package_vendor_all_project/vendor/sample/src/sample.brp" ]; then
            TOTAL=$((TOTAL + 1))
            record_pass "package vendor all writes source"
        else
            TOTAL=$((TOTAL + 1))
            record_fail "package vendor all writes source" \
                "missing $package_vendor_all_project/vendor/sample/src/sample.brp"
        fi
        expect_output_contains "package fetch hash ambiguity" 1 "matches multiple aliases" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package fetch "$3"' bash "$package_ambiguous_project" "$BLORP_BIN_ABS" "${package_hash:0:16}"
        expect_output_contains "package vendor explicit hash ignores config ambiguity" 0 "Vendored sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package vendor "$3" "$4"' bash "$package_ambiguous_project" "$BLORP_BIN_ABS" "${package_hash:0:16}" "$TMPDIR_CLI/package_vendor_hash_explicit"
        if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
            package_http_dir="$TMPDIR_CLI/package_http"
            package_http_port_file="$TMPDIR_CLI/package_http_port"
            package_http_cache="$TMPDIR_CLI/package_http_cache"
            mkdir -p "$package_http_dir" "$package_http_cache"
            cp "$package_artifact" "$package_http_dir/sample.blorpkg"
            python3 - "$package_http_dir" "$package_http_port_file" <<'PY' &
import http.server
import socketserver
import sys

directory = sys.argv[1]
port_file = sys.argv[2]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=directory, **kwargs)

    def log_message(self, format, *args):
        pass

class QuietTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

with QuietTCPServer(("127.0.0.1", 0), QuietHandler) as httpd:
    with open(port_file, "w", encoding="utf-8") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
            package_http_pid=$!
            CHILD_PIDS+=("$package_http_pid")
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                [ -f "$package_http_port_file" ] && break
                sleep 0.1
            done
            if [ -f "$package_http_port_file" ]; then
                package_http_port=$(cat "$package_http_port_file")
                expect_output_contains "package fetch http success" 0 "Hash $package_hash" \
                    env BLORP_PACKAGE_CACHE="$package_http_cache" "$BLORP_BIN" package fetch "$package_hash" "http://127.0.0.1:$package_http_port/sample.blorpkg"
            else
                TOTAL=$((TOTAL + 1))
                record_fail "package fetch http success" "local http server did not start"
            fi
        fi
        expect_exit "check cached package alias project" 0 \
            env BLORP_PACKAGE_CACHE="$package_cache" "$BLORP_BIN" check --no-format "$package_cache_project/app/main.brp"
        expect_exit "check cached package renamed alias project" 0 \
            env BLORP_PACKAGE_CACHE="$package_alias_cache" "$BLORP_BIN" check --no-format "$package_cache_alias_project/app/main.brp"
        expect_output_contains "package vendor success" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_cache" "$BLORP_BIN" package vendor "$package_hash" "$package_vendor"
        expect_output_contains "package vendor alias success" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package vendor sample' bash "$package_cache_project" "$BLORP_BIN_ABS"
        expect_output_contains "package vendor alias idempotent" 0 "Already vendored sample" \
            env BLORP_PACKAGE_CACHE="$package_cache" bash -c 'cd "$1" && "$2" package vendor sample' bash "$package_cache_project" "$BLORP_BIN_ABS"
        if [ -f "$package_vendor/src/sample.brp" ]; then
            TOTAL=$((TOTAL + 1))
            record_pass "package vendor writes source"
        else
            TOTAL=$((TOTAL + 1))
            record_fail "package vendor writes source" "missing $package_vendor/src/sample.brp"
        fi
        if [ -f "$package_cache_project/vendor/sample/src/sample.brp" ]; then
            TOTAL=$((TOTAL + 1))
            record_pass "package vendor alias writes source"
        else
            TOTAL=$((TOTAL + 1))
            record_fail "package vendor alias writes source" \
                "missing $package_cache_project/vendor/sample/src/sample.brp"
        fi
    fi
    expect_exit "check package alias project" 0 "$BLORP_BIN" check --no-format "$package_project/app/main.brp"
    expect_exit "check package renamed alias project" 0 "$BLORP_BIN" check --no-format "$package_alias_project/app/main.brp"
fi

expect_exit "compile success" 0 "$BLORP_BIN" compile --no-format -o "$compiled_c" "$valid_prog"
expect_exit "compile bypasses legacy OCaml host" 0 \
	env BLORP_OCAML_HOST_BIN="$TMPDIR_CLI/missing-ocaml-host" \
	"$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/direct-compile.c" "$valid_prog"
expect_output_contains "compile AST bypasses semantic worker" 0 "Func main" \
	env BLORP_OCAML_MIDDLE_BIN="$TMPDIR_CLI/missing-ocaml-middle" \
	"$BLORP_BIN" compile --no-format --ast "$valid_prog"
expect_output_contains "compile stops in Blorp-owned Core tail" 0 "stopped after dce" \
	"$BLORP_BIN" compile --no-format \
		--dump-core-after=dce --dump-core-file="$late_core_dump" \
		--stop-after=dce -o "$late_stopped_c" "$valid_prog"
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
expect_exit "run bypasses legacy OCaml host" 0 \
	env BLORP_OCAML_HOST_BIN="$TMPDIR_CLI/missing-ocaml-host" \
	"$BLORP_BIN" run --no-format --timeout 5 "$valid_prog"

if $run_deep_checks; then
	expect_output_contains "compile reports missing semantic worker" 1 "semantic worker failure" \
		env BLORP_OCAML_MIDDLE_BIN="$TMPDIR_CLI/missing-ocaml-middle" \
		"$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/missing-middle.c" "$valid_prog"
	expect_output_contains "compile parse failure" 1 'expected `)` after function parameters' \
		"$BLORP_BIN" compile --no-format -o "$TMPDIR_CLI/parse_invalid.c" "$parse_invalid_prog"
	expect_exit "run type failure" 1 "$BLORP_BIN" run --no-format --timeout 5 "$invalid_prog"
	expect_output_contains "run parse failure" 1 'expected `)` after function parameters' \
		"$BLORP_BIN" run --no-format --timeout 5 "$parse_invalid_prog"
	expect_exit "run bad timeout" 1 "$BLORP_BIN" run --timeout not-an-int "$valid_prog"
fi

expect_exit "test success" 0 "$BLORP_BIN" test --no-cache --no-format --timeout 5 tests/test_blorp/types/test_bool.brp
expect_exit "test failure" 1 "$BLORP_BIN" test --no-cache --no-format --timeout 5 "$failing_test"

if $run_deep_checks; then
	expect_exit "test bad timeout" 1 "$BLORP_BIN" test --timeout not-an-int tests/test_blorp/types/test_bool.brp
	expect_exit "test bad repeat" 1 "$BLORP_BIN" test --repeat 0 tests/test_blorp/types/test_bool.brp
	expect_exit "test warmup only accepts prior options" 0 "$BLORP_BIN" test --no-format --warmup-only
	expect_exit "test warmup only validates later options" 1 "$BLORP_BIN" test --warmup-only --bogus
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
fi

expect_exit "format check success" 0 "$BLORP_BIN" format --check "$valid_prog"
expect_exit "format check failure" 1 "$BLORP_BIN" format --check tests/test_compiler/format/should_fail/bad_spacing.brp

if $run_deep_checks; then
	expect_exit "format check empty file" 0 "$BLORP_BIN" format --check "$empty_prog"
	expect_exit "format missing file arg" 1 "$BLORP_BIN" format --check
	expect_output_contains "format rejects emit JSON with check" 1 "cannot be combined" \
		"$BLORP_BIN" format --check --emit-program-json "$valid_prog"
	expect_output_contains "format diff implies check" 1 "needs formatting" \
		"$BLORP_BIN" format --diff tests/test_compiler/format/should_fail/bad_spacing.brp
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
    if "$BLORP_BIN" compile --no-format -o "$formatter_tool_c" tools/formatter/formatter.brp > "$formatter_err" 2>&1 \
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
    echo "BLORP_GATE_RESULT gate=$CLI_GATE_NAME status=FAIL passed=$PASS failed=$FAIL tests=$TOTAL"
else
    echo "BLORP_GATE_RESULT gate=$CLI_GATE_NAME status=PASS passed=$PASS failed=0 tests=$TOTAL"
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
