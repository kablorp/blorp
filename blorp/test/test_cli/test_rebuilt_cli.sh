#!/usr/bin/env bash
# Rebuild the current compiler and require its Blorp-owned test route.

set -u

cd "$(dirname "$0")/../../.."

usage() {
    echo "Usage: blorp/test/test_cli/test_rebuilt_cli.sh [--timeout SECONDS]"
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
rebuilt_diagnostic_bin="$rebuilt_cli_dir/blorp-diagnostic"
rebuilt_stamp="$rebuilt_cli_dir/build-stamp.h"
build_log="$rebuilt_cli_dir/build.log"
native_runtime="blorp/src/lsp/server/native_runtime.c"
trap 'rm -rf "$rebuilt_cli_dir"' EXIT

if ! "$compiler" compile --no-format -o "$rebuilt_cli_c" \
    blorp/src/main.brp \
    > "$build_log" 2>&1; then
    cat "$build_log" >&2
    exit 1
fi

# The smoke suite measures compiler allocations too. Build its own pair from
# the same emitted C, with truthful stamps rather than the standalone C
# fallback's unknown fields or the parent compiler's native build settings.
if ! python3 -B - "$compiler" "$rebuilt_stamp" "${BLORP_CC:-clang}" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, "blorp/test/test_cli")
from prepare_memory_compiler import compiler_version

def output(*args):
    return subprocess.check_output(args, text=True).strip()

source = compiler_version(Path(sys.argv[1]).resolve(), 0)
facts = {
    "COMMIT": output("git", "rev-parse", "HEAD"),
    "TARGET": output("scripts/target-triple"),
    "CHANNEL": "local",
    "DIRTY": "true" if output("git", "status", "--porcelain", "--untracked-files=no") else "false",
    "COMPILED_BY": "self-" + source["commit"].removesuffix("-dirty"),
    "CLI_OPTIMIZATION": "-O0",
    "RUNTIME_OPTIMIZATION": "-O0",
    "SPLIT": "1",
    "CC": output(sys.argv[3], "--version").splitlines()[0],
}
Path(sys.argv[2]).write_text("".join(
    f"#define BLORP_BUILD_STAMP_{name} {json.dumps(value)}\n"
    for name, value in facts.items()
))
PY
then
    exit 1
fi

for diagnostic_mode in 0 1; do
    output_bin="$rebuilt_cli_bin"
    if [ "$diagnostic_mode" = 1 ]; then
        output_bin="$rebuilt_diagnostic_bin"
    fi
    if ! "${BLORP_CC:-clang}" -O0 -fwrapv -pipe -w \
    -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
    "-DBLORP_MEMORY_DIAGNOSTICS=$diagnostic_mode" -include "$rebuilt_stamp" \
    -Iblorp/src/compiler/stage_01_generated_inputs \
    -Iblorp/src/compiler/stage_04_modules \
    -Iblorp/src/compiler/stage_06_typecheck/graph \
    -Iblorp/src/compiler/stage_06_typecheck/type_system \
    -Iblorp/src \
    -Iblorp/src/lib \
    -Iblorp/src/lsp/server \
    -Iblorp/src/test \
    "$rebuilt_cli_c" blorp/build/_build/blorp-cli/runtime_sources.c \
    "$native_runtime" \
    -lm -lpthread -o "$output_bin" >> "$build_log" 2>&1; then
        cat "$build_log" >&2
        exit 1
    fi
done

smoke_output=$(
    env BLORP_BIN="$rebuilt_cli_bin" BLORP_DIAGNOSTIC_BIN="$rebuilt_diagnostic_bin" \
        blorp/test/test_cli/test_cli.sh --smoke --timeout "$test_timeout" 2>&1
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
