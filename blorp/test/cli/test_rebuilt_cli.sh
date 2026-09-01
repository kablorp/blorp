#!/usr/bin/env bash
# Rebuild the current compiler and require its Blorp-owned test route.

set -u

cd "$(dirname "$0")/../../.."

usage() {
    echo "Usage: blorp/test/cli/test_rebuilt_cli.sh [--timeout SECONDS]"
}

test_timeout="${BLORP_TEST_TIMEOUT:-60}"
while [ $# -gt 0 ]; do
    case "$1" in
        --timeout)
            if [ $# -lt 2 ]; then
                usage >&2
                exit 1
            fi
            test_timeout="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
done

case "$test_timeout" in
    ''|*[!0-9]*)
        echo "Error: --timeout must be a non-negative integer." >&2
        exit 1
        ;;
esac

compiler="${BLORP_BIN:-bin/blorp}"
rebuilt_cli_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_rebuilt_cli.XXXXXX") || exit 1
rebuilt_cli_c="$rebuilt_cli_dir/blorp.c"
rebuilt_cli_bin="$rebuilt_cli_dir/blorp"
build_log="$rebuilt_cli_dir/build.log"
native_runtime="blorp/src/lsp/server/native_runtime.c"
trap 'rm -rf "$rebuilt_cli_dir"' EXIT

if ! "$compiler" compile --no-format -o "$rebuilt_cli_c" \
    blorp/src/main.brp \
    > "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi

if ! "${CC:-cc}" -O0 -fwrapv -pipe -w \
    -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
    -Iblorp/src/compiler/stage_01_generated_inputs \
    -Iblorp/src/compiler/stage_06_typecheck/graph \
    -Iblorp/src \
    -Iblorp/src/lib \
    -Iblorp/src/lsp/server \
    -Iblorp/src/test \
    "$rebuilt_cli_c" blorp/build/_build/blorp-cli/runtime_sources.c \
    "$native_runtime" \
    -lm -lpthread -o "$rebuilt_cli_bin" >> "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi

smoke_output=$(
    env BLORP_BIN="$rebuilt_cli_bin" \
        blorp/test/cli/test_cli.sh --smoke --timeout "$test_timeout" 2>&1
)
smoke_code=$?

if [ "$smoke_code" -ne 0 ] \
    || ! grep -qF \
        "PASS: suite counters are stable across repeat" <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: eligible multiple suites run in one compiler batch" <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: memory suite runs without cwd isolation" \
        <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: default mixed TestSuite and doctest directory succeeds" \
        <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: configured standard-library doctest succeeds" <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: eligible suite runs with terminal stdin closed" \
        <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: eligible suite handles SIGTERM during host discovery" \
        <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: eligible suite handles SIGTERM" <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: Blorp-owned test emits requested gate summary" \
        <<<"$smoke_output" \
    || ! grep -qF \
        "PASS: test warmup succeeds" <<<"$smoke_output"; then
    printf '%s\n' "$smoke_output" >&2
    exit 1
fi

echo "PASS: rebuilt compiler exercises Blorp-owned test route"
echo "BLORP_GATE_RESULT gate=cli_rebuilt status=PASS passed=1 failed=0 tests=1"
