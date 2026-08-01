#!/usr/bin/env bash
# Regression tests for the top-level scripts/test harness.

set -u

cd "$(dirname "$0")/.."

expected_core_sanitize_root_count=55
actual_core_sanitize_root_count=$(awk 'NF { count += 1 } END { print count + 0 }' \
	scripts/compiler-core-sanitize-roots.txt)
if [ "$actual_core_sanitize_root_count" -ne "$expected_core_sanitize_root_count" ]; then
	echo "FAIL: compiler Core sanitizer manifest should contain $expected_core_sanitize_root_count roots"
	exit 1
fi

duplicate_core_sanitize_roots=$(sort scripts/compiler-core-sanitize-roots.txt | uniq -d)
if [ -n "$duplicate_core_sanitize_roots" ]; then
	echo "FAIL: compiler Core sanitizer manifest should not contain duplicate roots"
	echo "$duplicate_core_sanitize_roots"
	exit 1
fi

while IFS= read -r root; do
	[ -n "$root" ] || continue
	if [ ! -f "$root" ]; then
		echo "FAIL: compiler Core sanitizer root does not exist: $root"
		exit 1
	fi
done < scripts/compiler-core-sanitize-roots.txt

required_core_sanitize_roots=(
	compiler/blorp/tests/test_compiler_core_c_type_layout.brp
	compiler/blorp/tests/test_compiler_core_closure_identity.brp
	compiler/blorp/tests/test_compiler_core_early_invariants.brp
	compiler/blorp/tests/test_compiler_core_fairness.brp
	compiler/blorp/tests/test_compiler_core_late_invariants.brp
	compiler/blorp/tests/test_compiler_core_match_projection.brp
	compiler/blorp/tests/test_compiler_core_perceus.brp
	compiler/blorp/tests/test_compiler_core_pipeline.brp
	compiler/blorp/tests/test_compiler_core_prepare.brp
	compiler/blorp/tests/test_compiler_core_resource.brp
	compiler/blorp/tests/test_compiler_core_reuse.brp
)
for root in "${required_core_sanitize_roots[@]}"; do
	if ! grep -Fxq "$root" scripts/compiler-core-sanitize-roots.txt; then
		echo "FAIL: compiler Core sanitizer manifest is missing required root: $root"
		exit 1
	fi
done

TMP_HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/blorp_script_harness.XXXXXX") || exit 1
trap 'rm -rf "$TMP_HARNESS"' EXIT

mkdir -p \
	"$TMP_HARNESS/scripts" \
	"$TMP_HARNESS/std" \
	"$TMP_HARNESS/tests/test_blorp/memory" \
	"$TMP_HARNESS/tests/test_blorp/types"
cp scripts/test "$TMP_HARNESS/scripts/test"
cp scripts/compiler-core-sanitize-roots.txt "$TMP_HARNESS/scripts/compiler-core-sanitize-roots.txt"

cat > "$TMP_HARNESS/scripts/blorp-compiler-bootstrap" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "--print-path" ]; then
	printf '%s\n' "$TMP_HARNESS/pinned-blorp"
	exit 0
fi
exit 2
SH
chmod +x "$TMP_HARNESS/scripts/blorp-compiler-bootstrap"
cp /bin/sh "$TMP_HARNESS/pinned-blorp"

cat > "$TMP_HARNESS/Makefile" <<'MAKE'
all install build:
	@printf '%s\n' "$@" >> make-target-log.txt
MAKE

cat > "$TMP_HARNESS/std/prelude.brp" <<'BRP'
func main(args: List[String]) -> Int:
	0
BRP

write_fake_blorp() {
	local fake_check_log="$1"
	cat > "$TMP_HARNESS/blorp" <<SH
#!/usr/bin/env bash
set -u

if [ "\${1:-}" = "check" ]; then
	echo "\$*" >> "$fake_check_log"
	exit 0
fi

if [ "\${1:-}" = "__compiler-bridge-prepare" ]; then
	if [ -n "\${BLORP_TEST_PREPARE_MARKER:-}" ]; then
		: > "\$BLORP_TEST_PREPARE_MARKER"
	fi
	prepare_dir="\${2:-}"
	if [ -z "\$prepare_dir" ]; then
		echo "missing prepare directory" >&2
		exit 2
	fi
	mkdir -p "\$prepare_dir"
	echo "BLORP_COMPILER_RENDERER_BRIDGE_BIN=\$prepare_dir/compiler_renderer_bridge.bin"
	echo "BLORP_COMPILER_PARSER_BRIDGE_BIN=\$prepare_dir/compiler_parser_bridge.bin"
	echo "BLORP_COMPILER_TYPECHECK_BRIDGE_BIN=\$prepare_dir/compiler_typecheck_bridge.bin"
	exit 0
fi

if [ "\${1:-}" = "test" ]; then
	if [ -n "\${BLORP_TEST_EXPECTED_BOOTSTRAP:-}" ]; then
		if [ "\${BLORP_COMPILER_BRIDGE_BIN:-}" != "\$BLORP_TEST_EXPECTED_BOOTSTRAP" ] \
			|| [ ! -n "\${BLORP_COMPILER_RENDERER_BRIDGE_BIN:-}" ] \
			|| [ ! -n "\${BLORP_COMPILER_PARSER_BRIDGE_BIN:-}" ] \
			|| [ ! -n "\${BLORP_COMPILER_TYPECHECK_BRIDGE_BIN:-}" ] \
			|| [ "\${BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE:-}" != "1" ]; then
			echo "test command did not receive current helpers built by the pinned bootstrap" >&2
			exit 3
		fi
	fi
	if [ -n "\${BLORP_TEST_EXPECTED_RENDERER:-}" ] \
		&& { [ "\${BLORP_COMPILER_RENDERER_BRIDGE_BIN:-}" != "\$BLORP_TEST_EXPECTED_RENDERER" ] \
			|| [ "\${BLORP_COMPILER_PARSER_BRIDGE_BIN:-}" != "\$BLORP_TEST_EXPECTED_PARSER" ] \
			|| [ "\${BLORP_COMPILER_TYPECHECK_BRIDGE_BIN:-}" != "\$BLORP_TEST_EXPECTED_TYPECHECK" ]; }
	then
		echo "test command did not preserve explicit bridge helper paths" >&2
		exit 4
	fi
	echo "\$*" >> "$TMP_HARNESS/test-command-log.txt"
	echo "Results: 1 passed, 0 failed (1 tests)"
	if [ -n "\${BLORP_GATE_RESULT:-}" ]; then
		echo "BLORP_GATE_RESULT gate=\$BLORP_GATE_RESULT status=PASS passed=1 failed=0 tests=1"
	fi
	exit "\${BLORP_TEST_COMMAND_EXIT:-1}"
fi

echo "unexpected fake blorp command: \$*" >&2
exit 2
SH
	chmod +x "$TMP_HARNESS/blorp"
}

output_file="$TMP_HARNESS/output.txt"
check_log="$TMP_HARNESS/check-log.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
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

if [ "$(cat "$TMP_HARNESS/make-target-log.txt")" != "install" ]; then
	echo "FAIL: a runtime gate should install the public CLI"
	cat "$TMP_HARNESS/make-target-log.txt"
	exit 1
fi

echo "PASS: scripts/test installs the public CLI for Blorp gates"

default_toolchain_output="$TMP_HARNESS/default-toolchain-output.txt"
prepare_marker="$TMP_HARNESS/prepare-marker"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_EXPECTED_BOOTSTRAP="$TMP_HARNESS/pinned-blorp" \
		BLORP_TEST_PREPARE_MARKER="$prepare_marker" \
		BLORP_TEST_COMMAND_EXIT=0 \
		bash scripts/test runtime --serial
) > "$default_toolchain_output" 2>&1
default_toolchain_status=$?

if [ "$default_toolchain_status" -ne 0 ]; then
	echo "FAIL: scripts/test should prepare current bridge helpers with the pinned bootstrap"
	cat "$default_toolchain_output"
	exit 1
fi
if [ ! -e "$prepare_marker" ]; then
	echo "FAIL: scripts/test must prepare the current bridge helper sources"
	cat "$default_toolchain_output"
	exit 1
fi

echo "PASS: scripts/test prepares current bridge helpers with the pinned bootstrap"

rm -f "$TMP_HARNESS/make-target-log.txt"
no_build_output="$TMP_HARNESS/no-build-output.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_EXPECTED_BOOTSTRAP="$TMP_HARNESS/pinned-blorp" \
		BLORP_TEST_COMMAND_EXIT=0 \
		bash scripts/test runtime --serial --no-build
) > "$no_build_output" 2>&1
no_build_status=$?

if [ "$no_build_status" -ne 0 ]; then
	echo "FAIL: scripts/test --no-build should exercise an existing toolchain"
	cat "$no_build_output"
	exit 1
fi
if [ -s "$TMP_HARNESS/make-target-log.txt" ]; then
	echo "FAIL: scripts/test --no-build must not invoke make"
	cat "$TMP_HARNESS/make-target-log.txt"
	exit 1
fi

echo "PASS: scripts/test can test a prebuilt toolchain without rebuilding it"

external_helpers="$TMP_HARNESS/external-helpers"
mkdir -p "$external_helpers"
external_renderer="$external_helpers/renderer"
external_parser="$external_helpers/parser"
external_typecheck="$external_helpers/typecheck"
for executable in "$external_renderer" "$external_parser" "$external_typecheck"; do
	cp /bin/sh "$executable"
done
explicit_helpers_output="$TMP_HARNESS/explicit-helpers-output.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$external_renderer" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$external_parser" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$external_typecheck" \
		BLORP_TEST_EXPECTED_RENDERER="$external_renderer" \
		BLORP_TEST_EXPECTED_PARSER="$external_parser" \
		BLORP_TEST_EXPECTED_TYPECHECK="$external_typecheck" \
		BLORP_TEST_COMMAND_EXIT=0 \
		bash scripts/test runtime --serial --no-build
) > "$explicit_helpers_output" 2>&1
explicit_helpers_status=$?

if [ "$explicit_helpers_status" -ne 0 ]; then
	echo "FAIL: scripts/test --no-build should preserve explicit helper paths"
	cat "$explicit_helpers_output"
	exit 1
fi

echo "PASS: scripts/test preserves an explicitly selected prebuilt helper generation"

partial_toolchain_output="$TMP_HARNESS/partial-toolchain-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test runtime --serial
) > "$partial_toolchain_output" 2>&1
partial_toolchain_status=$?

if [ "$partial_toolchain_status" -eq 0 ]; then
	echo "FAIL: scripts/test must reject partial bridge helper overrides"
	cat "$partial_toolchain_output"
	exit 1
fi
if ! grep -Fq "bridge helper overrides must be provided together" \
	"$partial_toolchain_output"
then
	echo "FAIL: scripts/test must explain partial bridge helper overrides"
	cat "$partial_toolchain_output"
	exit 1
fi

echo "PASS: scripts/test rejects partial bridge helper overrides"

if ! grep -Fxq 'test --no-format --timeout 30 tests/test_blorp/types/' "$TMP_HARNESS/test-command-log.txt"; then
	echo "FAIL: scripts/test runtime should enumerate non-memory runtime categories"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

if grep -Fq 'tests/test_blorp/memory' "$TMP_HARNESS/test-command-log.txt" \
	|| grep -Fxq 'test --no-format --timeout 30 tests/test_blorp/' "$TMP_HARNESS/test-command-log.txt"; then
	echo "FAIL: scripts/test runtime should leave memory suites to the leak gate"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

echo "PASS: scripts/test runtime leaves memory suites to the leak gate"

if [ -f "$check_log" ]; then
	echo "FAIL: scripts/test runtime should not run a hidden std check"
	cat "$output_file"
	cat "$check_log"
	exit 1
fi

std_check_output_file="$TMP_HARNESS/std-check-output.txt"
std_check_log="$TMP_HARNESS/std-check-log.txt"
write_fake_blorp "$std_check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test std-check --serial
) > "$std_check_output_file" 2>&1
std_check_status=$?

if [ "$std_check_status" -ne 0 ]; then
	echo "FAIL: scripts/test std-check should pass when blorp check std passes"
	cat "$std_check_output_file"
	exit 1
fi

if ! grep -Eq 'Std-check[[:space:]]+PASS' "$std_check_output_file"; then
	echo "FAIL: scripts/test std-check should render an explicit std-check gate"
	cat "$std_check_output_file"
	exit 1
fi

if ! grep -Fxq 'check --no-format --std-dir std std' "$std_check_log"; then
	echo "FAIL: scripts/test std-check should check std with explicit stdlib context"
	cat "$std_check_output_file"
	cat "$std_check_log"
	exit 1
fi

echo "PASS: scripts/test std-check is explicit"

mkdir -p "$TMP_HARNESS/compiler/blorp/tests"
compiler_blorp_sanitize_log="$TMP_HARNESS/compiler-blorp-sanitize-log.txt"
cat > "$TMP_HARNESS/blorp" <<SH
#!/usr/bin/env bash
set -u

if [ "\${1:-}" = "__compiler-bridge-prepare" ]; then
	prepare_dir="\${2:-}"
	mkdir -p "\$prepare_dir"
	echo "BLORP_COMPILER_RENDERER_BRIDGE_BIN=\$prepare_dir/compiler_renderer_bridge.bin"
	echo "BLORP_COMPILER_PARSER_BRIDGE_BIN=\$prepare_dir/compiler_parser_bridge.bin"
	echo "BLORP_COMPILER_TYPECHECK_BRIDGE_BIN=\$prepare_dir/compiler_typecheck_bridge.bin"
	exit 0
fi

if [ "\${1:-}" = "test" ]; then
	echo "\$*" >> "$compiler_blorp_sanitize_log"
	echo "Results: 1 passed, 0 failed (1 tests)"
	echo "BLORP_GATE_RESULT gate=\${BLORP_GATE_RESULT:-missing} status=PASS passed=1 failed=0 tests=1"
	exit 0
fi

echo "unexpected fake blorp command: \$*" >&2
exit 2
SH
chmod +x "$TMP_HARNESS/blorp"

compiler_blorp_sanitize_output="$TMP_HARNESS/compiler-blorp-sanitize-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test compiler-blorp-sanitize --serial
) > "$compiler_blorp_sanitize_output" 2>&1
compiler_blorp_sanitize_status=$?

if [ "$compiler_blorp_sanitize_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-blorp-sanitize should run as an explicit gate"
	cat "$compiler_blorp_sanitize_output"
	exit 1
fi

expected_compiler_sanitize_timeout=180
expected_blorp_sanitize_command="test --no-format --no-cache --sanitize -j 1 --timeout $expected_compiler_sanitize_timeout compiler/blorp/tests/"
if ! grep -Fxq "$expected_blorp_sanitize_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-blorp-sanitize should be uncached, sanitized, and sequential"
	cat "$compiler_blorp_sanitize_output"
	cat "$compiler_blorp_sanitize_log"
	exit 1
fi

if ! grep -Eq 'Compiler-Blorp-ASan[[:space:]]+PASS' "$compiler_blorp_sanitize_output"; then
	echo "FAIL: scripts/test should render the compiler Blorp sanitizer gate"
	cat "$compiler_blorp_sanitize_output"
	exit 1
fi

echo "PASS: scripts/test exposes an uncached compiler Blorp sanitizer gate"

mkdir -p "$TMP_HARNESS/tests/test_compiler/codegen_audit"
cat > "$TMP_HARNESS/tests/test_compiler/codegen_audit/run_codegen_audit.sh" <<'SH'
#!/usr/bin/env bash
echo "Results: 1 passed, 0 failed"
SH
chmod +x "$TMP_HARNESS/tests/test_compiler/codegen_audit/run_codegen_audit.sh"
cat > "$TMP_HARNESS/tests/test_compiler/run_compiler_tests.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${BLORP_COMPILER_BRIDGE_STATS:-}" ]; then
	echo "compiler tool fixtures inherited bridge diagnostics" >&2
	exit 3
fi
echo "BLORP_GATE_RESULT gate=compiler_deep_tools status=PASS passed=1 failed=0 tests=1"
SH
chmod +x "$TMP_HARNESS/tests/test_compiler/run_compiler_tests.sh"

: > "$compiler_blorp_sanitize_log"
compiler_blorp_output="$TMP_HARNESS/compiler-blorp-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test compiler-deep --serial --timings
) > "$compiler_blorp_output" 2>&1
compiler_blorp_status=$?

if [ "$compiler_blorp_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-deep should run compiler-owned Blorp suites"
	cat "$compiler_blorp_output"
	exit 1
fi

expected_compiler_blorp_timeout=180
expected_blorp_command="test --no-format --timeout $expected_compiler_blorp_timeout compiler/blorp/tests/"
if ! grep -Fxq "$expected_blorp_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-owned Blorp suites should use their measured timeout"
	cat "$compiler_blorp_output"
	cat "$compiler_blorp_sanitize_log"
	exit 1
fi

echo "PASS: scripts/test gives grouped compiler Blorp suites a measured timeout"

: > "$compiler_blorp_sanitize_log"
compiler_core_sanitize_output="$TMP_HARNESS/compiler-core-sanitize-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test compiler-core-sanitize --serial
) > "$compiler_core_sanitize_output" 2>&1
compiler_core_sanitize_status=$?

if [ "$compiler_core_sanitize_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-core-sanitize should run as an explicit gate"
	cat "$compiler_core_sanitize_output"
	exit 1
fi

expected_core_sanitize_prefix="test --no-format --no-cache --sanitize -j 1 --timeout $expected_compiler_sanitize_timeout"
expected_core_sanitize_roots=$(tr '\n' ' ' < scripts/compiler-core-sanitize-roots.txt)
expected_core_sanitize_roots=${expected_core_sanitize_roots% }
expected_core_sanitize_command="$expected_core_sanitize_prefix $expected_core_sanitize_roots"
if ! grep -Fxq "$expected_core_sanitize_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-core-sanitize should use the explicit uncached serial Core file set"
	cat "$compiler_core_sanitize_output"
	cat "$compiler_blorp_sanitize_log"
	exit 1
fi

if ! grep -Eq 'Compiler-Core-ASan[[:space:]]+PASS' "$compiler_core_sanitize_output"; then
	echo "FAIL: scripts/test should render the focused compiler Core sanitizer gate"
	cat "$compiler_core_sanitize_output"
	exit 1
fi

echo "PASS: scripts/test exposes the explicit focused compiler Core sanitizer gate"

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
scope=""
timings=false
timing_run_id=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--scope=*)
			scope="${1#--scope=}"
			;;
		--timings)
			timings=true
			;;
		--timing-run-id=*)
			timing_run_id="${1#--timing-run-id=}"
			;;
	esac
	shift
done
if [ "$scope" != "default" ]; then
	echo "missing compiler unit scope arg" >&2
	exit 3
fi
if [ "$timings" != "true" ]; then
	echo "missing compiler unit timing arg" >&2
	exit 3
fi
if [ -z "$timing_run_id" ]; then
	echo "missing compiler unit timing run id arg" >&2
	exit 3
fi
printf 'BLORP_COMPILER_UNIT_TIMING\t%s\tdefault\tSlowSuite.group\tcase one\t1.234000\n' "$timing_run_id"
echo "Test Successful in 0.001s. 1 tests run."
exit 0
SH
chmod +x "$TMP_HARNESS/bin/dune"

timing_output_file="$TMP_HARNESS/unit-timing-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		PATH="$TMP_HARNESS/bin:$PATH" \
		bash scripts/test compiler-unit --serial --timings
) > "$timing_output_file" 2>&1
timing_status=$?

if [ "$timing_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-unit --timings should pass through timing args"
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

mkdir -p "$TMP_HARNESS/compiler/blorp/tests"
cat > "$TMP_HARNESS/blorp" <<'SH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = "__compiler-bridge-prepare" ]; then
	prepare_dir="${2:-}"
	mkdir -p "$prepare_dir"
	echo "BLORP_COMPILER_RENDERER_BRIDGE_BIN=$prepare_dir/compiler_renderer_bridge.bin"
	echo "BLORP_COMPILER_PARSER_BRIDGE_BIN=$prepare_dir/compiler_parser_bridge.bin"
	echo "BLORP_COMPILER_TYPECHECK_BRIDGE_BIN=$prepare_dir/compiler_typecheck_bridge.bin"
	exit 0
fi

if [ "${1:-}" = "test" ]; then
	if [ "${BLORP_TEST_TIMINGS:-}" != "1" ]; then
		echo "missing BLORP_TEST_TIMINGS" >&2
		exit 3
	fi
	if [ "${BLORP_COMPILER_BRIDGE_STATS:-}" != "1" ]; then
		echo "missing BLORP_COMPILER_BRIDGE_STATS" >&2
		exit 3
	fi
	echo "BLORP_TEST_TIMING phase=frontend_graph group=run_all_0 suites=4 sources=4 duration_ms=1250"
	echo "BLORP_TEST_TIMING phase=host_c group=run_all_0 suites=4 sources=4 duration_ms=250"
	echo "Results: 1 passed, 0 failed (1 tests)"
	echo "BLORP_GATE_RESULT gate=${BLORP_GATE_RESULT:-compiler_blorp_sanitize} status=PASS passed=1 failed=0 tests=1"
	exit 0
fi

echo "unexpected fake blorp command: $*" >&2
exit 2
SH
chmod +x "$TMP_HARNESS/blorp"

generated_timing_output_file="$TMP_HARNESS/generated-timing-output.txt"
generated_timing_log_dir="$TMP_HARNESS/generated-timing-logs"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_COMPILER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_RENDERER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_PARSER_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$TMP_HARNESS/blorp" \
		bash scripts/test compiler-blorp-sanitize --serial --timings \
			--log-dir "$generated_timing_log_dir"
) > "$generated_timing_output_file" 2>&1
generated_timing_status=$?

if [ "$generated_timing_status" -ne 0 ]; then
	echo "FAIL: scripts/test generated-suite timing run should pass"
	cat "$generated_timing_output_file"
	exit 1
fi

if ! grep -Fq 'Generated TestSuite phase totals:' "$generated_timing_output_file"; then
	echo "FAIL: scripts/test should print generated-suite phase totals"
	cat "$generated_timing_output_file"
	exit 1
fi

if ! grep -Eq 'frontend_graph[[:space:]]+1 calls[[:space:]]+1\.250s' "$generated_timing_output_file"; then
	echo "FAIL: scripts/test should aggregate generated frontend timing"
	cat "$generated_timing_output_file"
	exit 1
fi

if ! grep -Eq 'host_c[[:space:]]+1 calls[[:space:]]+0\.250s' "$generated_timing_output_file"; then
	echo "FAIL: scripts/test should aggregate generated host-C timing"
	cat "$generated_timing_output_file"
	exit 1
fi

if ! grep -Fq \
	'BLORP_TEST_TIMING phase=frontend_graph group=run_all_0 suites=4 sources=4 duration_ms=1250' \
	"$generated_timing_log_dir/compiler-blorp-sanitize.log"; then
	echo "FAIL: scripts/test should preserve raw generated-suite timings in gate logs"
	cat "$generated_timing_output_file"
	exit 1
fi

echo "PASS: scripts/test prints generated-suite phase timing summaries"

cat > "$TMP_HARNESS/bin/dune" <<'SH'
#!/usr/bin/env bash
echo "Testing \`blorp'."
exit 0
SH
chmod +x "$TMP_HARNESS/bin/dune"

unit_output_file="$TMP_HARNESS/unit-output.txt"
: > "$TMP_HARNESS/make-target-log.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
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

if [ "$(cat "$TMP_HARNESS/make-target-log.txt")" != "build" ]; then
	echo "FAIL: compiler-unit should build only the OCaml compiler"
	cat "$TMP_HARNESS/make-target-log.txt"
	exit 1
fi

echo "PASS: scripts/test builds only the OCaml compiler for compiler-unit"
