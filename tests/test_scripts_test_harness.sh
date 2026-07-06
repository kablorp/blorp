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
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_PREFLIGHT_CACHE=0 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test runtime --serial
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

mkdir -p "$TMP_HARNESS/tests/test_compiler"
cat > "$TMP_HARNESS/tests/test_compiler/run_compiler_tests.sh" <<'SH'
#!/usr/bin/env bash
echo "Error: simulated infrastructure failure"
exit 1
SH
chmod +x "$TMP_HARNESS/tests/test_compiler/run_compiler_tests.sh"

compiler_output_file="$TMP_HARNESS/compiler-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_PREFLIGHT_CACHE=0 \
		bash scripts/test compiler --serial
) > "$compiler_output_file" 2>&1
compiler_status=$?

if [ "$compiler_status" -eq 0 ]; then
	echo "FAIL: scripts/test compiler should exit nonzero when the compiler runner exits nonzero"
	cat "$compiler_output_file"
	exit 1
fi

if ! grep -Fq 'Error: simulated infrastructure failure' "$compiler_output_file"; then
	echo "FAIL: scripts/test should show capitalized infrastructure errors in failure excerpts"
	cat "$compiler_output_file"
	exit 1
fi

if ! grep -Fq 'compiler gate exited before reporting a summary' "$compiler_output_file"; then
	echo "FAIL: scripts/test should still report the missing compiler summary"
	cat "$compiler_output_file"
	exit 1
fi

echo "PASS: scripts/test shows compiler infrastructure failures"

mkdir -p "$TMP_HARNESS/compiler" "$TMP_HARNESS/bin"

cat > "$TMP_HARNESS/bin/dune" <<'SH'
#!/usr/bin/env bash
if [ "${BLORP_COMPILER_UNIT_TIMINGS:-}" != "1" ]; then
	echo "missing compiler unit timing env" >&2
	exit 3
fi
if [ -z "${BLORP_COMPILER_UNIT_TIMING_RUN_ID:-}" ]; then
	echo "missing compiler unit timing run id" >&2
	exit 3
fi
printf 'BLORP_COMPILER_UNIT_TIMING\t%s\tdefault\tSlowSuite.group\tcase one\t1.234000\n' "$BLORP_COMPILER_UNIT_TIMING_RUN_ID"
echo "Test Successful in 0.001s. 1 tests run."
exit 0
SH
chmod +x "$TMP_HARNESS/bin/dune"

timing_output_file="$TMP_HARNESS/unit-timing-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_PREFLIGHT_CACHE=0 \
		PATH="$TMP_HARNESS/bin:$PATH" \
		bash scripts/test compiler-unit --serial --timings
) > "$timing_output_file" 2>&1
timing_status=$?

if [ "$timing_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-unit --timings should pass through timing env"
	cat "$timing_output_file"
	exit 1
fi

if ! grep -Fq 'Slow compiler-unit cases:' "$timing_output_file"; then
	echo "FAIL: scripts/test --timings should print a slow case summary"
	cat "$timing_output_file"
	exit 1
fi

if ! grep -Fq '1.234s  SlowSuite.group :: case one' "$timing_output_file"; then
	echo "FAIL: scripts/test --timings should include the slow timed case"
	cat "$timing_output_file"
	exit 1
fi

echo "PASS: scripts/test prints compiler-unit timing summaries"

cat > "$TMP_HARNESS/bin/dune" <<'SH'
#!/usr/bin/env bash
echo "Testing \`blorp'."
exit 0
SH
chmod +x "$TMP_HARNESS/bin/dune"

unit_output_file="$TMP_HARNESS/unit-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_PREFLIGHT_CACHE=0 \
		PATH="$TMP_HARNESS/bin:$PATH" \
		bash scripts/test compiler-unit --serial
) > "$unit_output_file" 2>&1
unit_status=$?

if [ "$unit_status" -eq 0 ]; then
	echo "FAIL: scripts/test compiler-unit should exit nonzero when Alcotest summary parsing fails"
	cat "$unit_output_file"
	exit 1
fi

if ! grep -Eq 'Compiler-unit[[:space:]]+FAIL' "$unit_output_file"; then
	echo "FAIL: scripts/test should render compiler-unit as FAIL when no Alcotest summary is parsed"
	cat "$unit_output_file"
	exit 1
fi

echo "PASS: scripts/test exits nonzero when gate summary parsing fails"
