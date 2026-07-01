#!/bin/bash
# Thin wrapper for compiler tests. The actual runner lives in a test-only Dune
# executable so the shipped `blorp` CLI does not expose compiler fixture
# plumbing.

cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd -P)

verbose=false
run_codegen_audit=true
case_selection=all
gate_name=compiler
jobs_args=()

usage() {
    echo "Usage: tests/test_compiler/run_compiler_tests.sh [--quiet|--verbose] [-j N] [--no-codegen-audit] [--no-tool-fixtures|--only-tool-fixtures] [--gate-name NAME]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --verbose)
            verbose=true
            ;;
        --quiet)
            verbose=false
            ;;
        -j)
            if [ $# -lt 2 ]; then
                echo "Error: -j requires a worker count" >&2
                exit 1
            fi
            jobs_args=(-j "$2")
            shift
            ;;
        --no-codegen-audit)
            run_codegen_audit=false
            ;;
        --no-tool-fixtures)
            if [ "$case_selection" = "tool" ]; then
                echo "Error: --no-tool-fixtures and --only-tool-fixtures are mutually exclusive" >&2
                exit 1
            fi
            case_selection=surface
            ;;
        --only-tool-fixtures)
            if [ "$case_selection" = "surface" ]; then
                echo "Error: --no-tool-fixtures and --only-tool-fixtures are mutually exclusive" >&2
                exit 1
            fi
            case_selection=tool
            ;;
        --gate-name)
            if [ $# -lt 2 ]; then
                echo "Error: --gate-name requires a name" >&2
                exit 1
            fi
            gate_name="$2"
            shift
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
    shift
done

if [ -n "${BLORP_BIN:-}" ]; then
    BLORP_BIN="$BLORP_BIN"
elif [ -f "$REPO_ROOT/blorp" ]; then
    BLORP_BIN="$REPO_ROOT/blorp"
else
    echo "Error: blorp compiler not found. Run 'make' first." >&2
    exit 1
fi

compiler_test_timeout="${BLORP_COMPILER_TEST_TIMEOUT:-${BLORP_TEST_TIMEOUT:-30}}"
case "$compiler_test_timeout" in
    ''|*[!0-9]*)
        echo "Error: BLORP_COMPILER_TEST_TIMEOUT must be a non-negative integer." >&2
        exit 1
        ;;
esac

runner_args=(--blorp-bin "$BLORP_BIN" --timeout "$compiler_test_timeout" --gate-name "$gate_name")

if $verbose; then
    runner_args+=(--verbose)
else
    runner_args+=(--quiet)
fi

if ! $run_codegen_audit; then
    runner_args+=(--no-codegen-audit)
fi

case "$case_selection" in
    surface)
        runner_args+=(--no-tool-fixtures)
        ;;
    tool)
        runner_args+=(--only-tool-fixtures)
        ;;
esac

(cd "$REPO_ROOT/compiler" && dune build ./test/runner/compiler_fixture_runner.exe)
exec "$REPO_ROOT/compiler/_build/default/test/runner/compiler_fixture_runner.exe" "${runner_args[@]}" "${jobs_args[@]}"
