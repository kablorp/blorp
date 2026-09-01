#!/usr/bin/env bash
# Package command and lifecycle contract tests.

set -u

cd "$(dirname "$0")/../../.."

usage() {
    cat <<'EOF'
Usage: blorp/test/package/test_package.sh [--timeout SECONDS] [--gate-name NAME]

Options:
  --timeout SECONDS    Per-command timeout. Defaults to BLORP_TEST_TIMEOUT or 60.
  --gate-name NAME     Gate name emitted in the BLORP_GATE_RESULT summary.
EOF
}

CLI_GATE_NAME="package"
CLI_TIMEOUT="${BLORP_TEST_TIMEOUT:-60}"
while [ $# -gt 0 ]; do
    case "$1" in
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

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed ($TOTAL package checks)"
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

package_ok="$TMPDIR_CLI/package_ok"
package_bad="$TMPDIR_CLI/package_bad"
package_builtin_body="$TMPDIR_CLI/package_builtin_body"
package_nested_builtin="$TMPDIR_CLI/package_nested_builtin"
package_foreign="$TMPDIR_CLI/package_foreign"
package_builtin_type="$TMPDIR_CLI/package_builtin_type"
package_project="$TMPDIR_CLI/package_project"
package_alias_project="$TMPDIR_CLI/package_alias_project"
package_reserved_alias_project="$TMPDIR_CLI/package_reserved_alias_project"
package_unsupported_key_project="$TMPDIR_CLI/package_unsupported_key_project"
package_wrong_type_project="$TMPDIR_CLI/package_wrong_type_project"
package_duplicate_field_project="$TMPDIR_CLI/package_duplicate_field_project"
package_empty_table_project="$TMPDIR_CLI/package_empty_table_project"
package_cache_project="$TMPDIR_CLI/package_cache_project"
package_cache_alias_project="$TMPDIR_CLI/package_cache_alias_project"
package_ambiguous_project="$TMPDIR_CLI/package_ambiguous_project"
package_vendor_all_project="$TMPDIR_CLI/package_vendor_all_project"
package_local_hash_project="$TMPDIR_CLI/package_local_hash_project"
package_cache="$TMPDIR_CLI/package_cache"
package_alias_cache="$TMPDIR_CLI/package_alias_cache"
package_fetch_all_cache="$TMPDIR_CLI/package_fetch_all_cache"
package_local_hash_cache="$TMPDIR_CLI/package_local_hash_cache"
package_missing_cache="$TMPDIR_CLI/package_missing_cache"
package_mismatch_cache="$TMPDIR_CLI/package_mismatch_cache"
package_corrupt_cache="$TMPDIR_CLI/package_corrupt_cache"
package_incomplete_cache="$TMPDIR_CLI/package_incomplete_cache"
package_tampered_cache="$TMPDIR_CLI/package_tampered_cache"
package_collision_cache="$TMPDIR_CLI/package_collision_cache"
package_artifact="$TMPDIR_CLI/sample.blorpkg"
package_corrupt_artifact="$TMPDIR_CLI/corrupt.blorpkg"
package_vendor="$TMPDIR_CLI/vendor_sample"
package_tampered_vendor="$TMPDIR_CLI/vendor_tampered"

mkdir -p "$package_ok/src/sample/internal" "$package_bad/src"
mkdir -p "$package_builtin_body/src" "$package_nested_builtin/src"
mkdir -p "$package_foreign/src" "$package_builtin_type/src"
mkdir -p "$package_project/app" "$package_project/vendor"
mkdir -p "$package_alias_project/app" "$package_alias_project/vendor"
mkdir -p "$package_reserved_alias_project" "$package_unsupported_key_project"
mkdir -p "$package_wrong_type_project"
mkdir -p "$package_duplicate_field_project" "$package_empty_table_project"
mkdir -p "$package_cache_project/app" "$package_cache_alias_project/app"
mkdir -p "$package_ambiguous_project" "$package_vendor_all_project"
mkdir -p "$package_local_hash_project"
mkdir -p "$package_cache" "$package_alias_cache" "$package_fetch_all_cache" "$package_local_hash_cache"
mkdir -p "$package_missing_cache"
mkdir -p "$package_mismatch_cache" "$package_corrupt_cache" "$package_incomplete_cache"
mkdir -p "$package_tampered_cache" "$package_collision_cache"
printf 'not a blorp package artifact' > "$package_corrupt_artifact"

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

cat > "$package_ok/src/sample/helper.brp" <<'BRP'
pure func helper_value() -> Int:
	1
BRP

cat > "$package_ok/src/sample/internal/helper.brp" <<'BRP'
pure func helper_value() -> Int:
	2
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

for package_fixture in \
    "$package_builtin_body" \
    "$package_nested_builtin" \
    "$package_foreign" \
    "$package_builtin_type"; do
    cat > "$package_fixture/package.toml" <<'TOML'
[package]
name = "sample"

[compat]
std = "preview-1"

[exports]
modules = ["sample"]
TOML
done

cat > "$package_builtin_body/src/sample.brp" <<'BRP'
pure func answer() -> Int:
	builtin("blorp_hash")
BRP

cat > "$package_nested_builtin/src/sample.brp" <<'BRP'
pure func answer() -> Void:
	value = builtin("blorp_hash")
	value
BRP

cat > "$package_foreign/src/sample.brp" <<'BRP'
foreign:
	func native_answer() -> Int

pure func answer() -> Int:
	0
BRP

cat > "$package_builtin_type/src/sample.brp" <<'BRP'
type NativeWord = builtin

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

cat > "$package_reserved_alias_project/blorp.toml" <<'TOML'
[packages]
pkg = { path = "vendor/pkg" }
TOML

cat > "$package_unsupported_key_project/blorp.toml" <<'TOML'
[packages]
sample = { url = "sample.blorpkg" }
TOML

cat > "$package_wrong_type_project/blorp.toml" <<'TOML'
[packages]
sample = { hash = 42, from = "sample.blorpkg" }
TOML

cat > "$package_duplicate_field_project/blorp.toml" <<'TOML'
packages.sample = { path = "vendor/one" }
packages.sample.path = "vendor/two"
TOML

cat > "$package_empty_table_project/blorp.toml" <<'TOML'
[packages.sample]
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

expect_output_contains "package help" 0 "Usage: blorp package" \
    "$BLORP_BIN" package --help
expect_output_contains "package check success" 0 "Package sample: ok" \
    "$BLORP_BIN" package check "$package_ok"
expect_output_contains "package check rejects external import" 1 "may import only std modules" \
    "$BLORP_BIN" package check "$package_bad"
expect_output_contains "package check rejects builtin function body" 1 "builtin expressions cannot be used in source packages" \
    "$BLORP_BIN" package check "$package_builtin_body"
expect_output_contains "package check rejects nested builtin expression" 1 "builtin expressions cannot be used in source packages" \
    "$BLORP_BIN" package check "$package_nested_builtin"
expect_output_contains "package check rejects foreign declaration" 1 "foreign' declarations cannot be used in source packages" \
    "$BLORP_BIN" package check "$package_foreign"
expect_output_contains "package check rejects builtin type" 1 "can only be used in the standard library" \
    "$BLORP_BIN" package check "$package_builtin_type"
expect_output_contains "package config rejects reserved alias" 1 'package alias `pkg` is reserved' \
    bash -c 'cd "$1" && "$2" package fetch' bash "$package_reserved_alias_project" "$BLORP_BIN_ABS"
expect_output_contains "package config rejects unsupported key" 1 'unsupported key `url`' \
    bash -c 'cd "$1" && "$2" package fetch' bash "$package_unsupported_key_project" "$BLORP_BIN_ABS"
expect_output_contains "package config rejects wrong value type" 1 "wrong value type" \
    bash -c 'cd "$1" && "$2" package fetch' bash "$package_wrong_type_project" "$BLORP_BIN_ABS"
expect_output_contains "package config rejects duplicate field" 1 "duplicate key" \
    bash -c 'cd "$1" && "$2" package fetch' bash "$package_duplicate_field_project" "$BLORP_BIN_ABS"
expect_output_contains "package config rejects empty table" 1 "must define path or hash" \
    bash -c 'cd "$1" && "$2" package fetch' bash "$package_empty_table_project" "$BLORP_BIN_ABS"


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
        expect_output_contains "package fetch rejects hash mismatch" 1 "package hash mismatch" \
            env BLORP_PACKAGE_CACHE="$package_mismatch_cache" "$BLORP_BIN" package fetch ffffffffffffffff "$package_artifact"
        TOTAL=$((TOTAL + 1))
        if [ ! -e "$package_mismatch_cache/blake3/${package_hash:0:16}" ]; then
            record_pass "package hash mismatch leaves no cache entry"
        else
            record_fail "package hash mismatch leaves no cache entry" \
                "unexpected cache entry $package_mismatch_cache/blake3/${package_hash:0:16}"
        fi
        expect_output_contains "package fetch rejects corrupt artifact" 1 "not a blorp package artifact" \
            env BLORP_PACKAGE_CACHE="$package_corrupt_cache" "$BLORP_BIN" package fetch ffffffffffffffff "$package_corrupt_artifact"
        TOTAL=$((TOTAL + 1))
        if [ ! -d "$package_corrupt_cache/blake3" ] \
            || [ -z "$(find "$package_corrupt_cache/blake3" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            record_pass "corrupt package artifact leaves no cache entry"
        else
            record_fail "corrupt package artifact leaves no cache entry" \
                "unexpected package hash directory under $package_corrupt_cache/blake3"
        fi
        mkdir -p "$package_incomplete_cache/blake3/${package_hash:0:16}"
        printf '%s\n' "$package_hash" > "$package_incomplete_cache/blake3/${package_hash:0:16}/HASH"
        expect_output_contains "package fetch replaces incomplete cache entry" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_incomplete_cache" "$BLORP_BIN" package fetch "$package_hash" "$package_artifact"
        expect_output_contains "package fetch primes tamper test cache" 0 "Hash $package_hash" \
            env BLORP_PACKAGE_CACHE="$package_tampered_cache" "$BLORP_BIN" package fetch "$package_hash" "$package_artifact"
        printf '%s\n' 'pure func answer() -> Int: 99' > "$package_tampered_cache/blake3/${package_hash:0:16}/src/sample.brp"
        expect_output_contains "package vendor rejects tampered cache" 1 "content hash mismatch" \
            env BLORP_PACKAGE_CACHE="$package_tampered_cache" "$BLORP_BIN" package vendor "$package_hash" "$package_tampered_vendor"
        TOTAL=$((TOTAL + 1))
        if [ ! -e "$package_tampered_vendor" ]; then
            record_pass "tampered package leaves no vendor destination"
        else
            record_fail "tampered package leaves no vendor destination" \
                "unexpected vendor destination $package_tampered_vendor"
        fi
        mkdir -p "$package_collision_cache/blake3/${package_hash:0:16}"
        printf '%s%s\n' "${package_hash:0:16}" 'ffffffffffffffffffffffffffffffffffffffffffffffff' \
            > "$package_collision_cache/blake3/${package_hash:0:16}/HASH"
        expect_output_contains "package fetch rejects cache prefix collision" 1 "package cache prefix collision" \
            env BLORP_PACKAGE_CACHE="$package_collision_cache" "$BLORP_BIN" package fetch "$package_hash" "$package_artifact"
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
        cat > "$package_local_hash_project/blorp.toml" <<TOML
[packages]
sample = { path = "../package_ok", hash = "${package_hash:0:16}" }
TOML
        expect_output_contains "package fetch all skips uncached local hash" 0 "Skipped local package sample" \
            env BLORP_PACKAGE_CACHE="$package_local_hash_cache" bash -c 'cd "$1" && "$2" package fetch' bash "$package_local_hash_project" "$BLORP_BIN_ABS"
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
        expect_output_contains "package vendor explicit destination is not idempotent" 1 "destination already exists" \
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

finish
