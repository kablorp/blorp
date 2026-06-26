#!/usr/bin/env bash
# Regression tests for the top-level scripts/test harness.

set -u

cd "$(dirname "$0")/.."

TMP_HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/blorp_script_harness.XXXXXX") || exit 1
trap 'rm -rf "$TMP_HARNESS"' EXIT

mkdir -p "$TMP_HARNESS/scripts" "$TMP_HARNESS/std" "$TMP_HARNESS/tests/test_blorp"
cp scripts/test "$TMP_HARNESS/scripts/test"

cat > "$TMP_HARNESS/Makefile" <<'MAKE'
all:
	@:
MAKE

cat > "$TMP_HARNESS/std/prelude.brp" <<'BRP'
func main(args: List[String]) -> Int:
	0
BRP

cat > "$TMP_HARNESS/blorp" <<'SH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = "check" ]; then
	exit 0
fi

if [ "${1:-}" = "test" ]; then
	echo "Results: 1 passed, 0 failed (1 tests)"
	if [ -n "${BLORP_GATE_RESULT:-}" ]; then
		echo "BLORP_GATE_RESULT gate=$BLORP_GATE_RESULT status=PASS passed=1 failed=0 tests=1"
	fi
	exit 1
fi

echo "unexpected fake blorp command: $*" >&2
exit 2
SH
chmod +x "$TMP_HARNESS/blorp"

output_file="$TMP_HARNESS/output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 BLORP_TEST_PREFLIGHT_CACHE=0 bash scripts/test runtime --serial
) > "$output_file" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
	echo "FAIL: scripts/test should exit nonzero when a gate command exits nonzero"
	cat "$output_file"
	exit 1
fi

if ! grep -Eq 'Runtime[[:space:]]+FAIL' "$output_file"; then
	echo "FAIL: scripts/test should render the runtime gate as FAIL"
	cat "$output_file"
	exit 1
fi

if ! grep -Fq 'runtime gate process exited with status 1 after reporting PASS' "$output_file"; then
	echo "FAIL: scripts/test should explain a process-status/summary mismatch"
	cat "$output_file"
	exit 1
fi

if grep -Eq 'Runtime[[:space:]]+PASS' "$output_file"; then
	echo "FAIL: scripts/test should not render a nonzero runtime gate as PASS"
	cat "$output_file"
	exit 1
fi

echo "PASS: scripts/test reports nonzero gate commands as failed"
