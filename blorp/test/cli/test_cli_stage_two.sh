#!/usr/bin/env bash
# Build one current-runtime compiler stage and require its Blorp-owned test route.

set -u

cd "$(dirname "$0")/../../.."

usage() {
    echo "Usage: blorp/test/cli/test_cli_stage_two.sh [--timeout SECONDS]"
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
stage_two_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_cli_stage_two.XXXXXX") || exit 1
stage_two_c="$stage_two_dir/blorp.c"
stage_two_bin="$stage_two_dir/blorp"
build_log="$stage_two_dir/build.log"
native_runtime="blorp/src/lsp/server/native_runtime.c"
trap 'rm -rf "$stage_two_dir"' EXIT

if ! "$compiler" compile --no-format -o "$stage_two_c" \
    blorp/src/main.brp \
    > "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi

if ! "${CC:-cc}" -O0 -fwrapv -pipe -w \
    -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
    -Iblorp/src/compiler/stage_01_file_io \
    -Iblorp/src/compiler/stage_06_typecheck/graph \
    -Iblorp/src \
    -Iblorp/src/lib \
    -Iblorp/src/lsp/server \
    -Iblorp/src/test \
    "$stage_two_c" blorp/build/_build/blorp-cli/runtime_sources.c \
    "$native_runtime" \
    -lm -lpthread -o "$stage_two_bin" >> "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi

smoke_output=$(
    env BLORP_BIN="$stage_two_bin" \
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

echo "PASS: stage-two compiler exercises Blorp-owned test route"
echo "BLORP_GATE_RESULT gate=cli_stage_two status=PASS passed=1 failed=0 tests=1"
