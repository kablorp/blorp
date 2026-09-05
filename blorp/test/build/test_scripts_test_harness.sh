#!/usr/bin/env bash
# Regression tests for the top-level scripts/test harness.

set -u

cd "$(dirname "$0")/../../.."

expected_core_sanitize_root_count=58
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
	blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp
	blorp/test/compiler/pipeline/test_core_c_type_layout.brp
	blorp/test/compiler/pipeline/test_core_closure_identity.brp
	blorp/test/compiler/stage_09_core/test_core_early_invariants.brp
	blorp/test/compiler/stage_09_core/test_core_fairness.brp
	blorp/test/compiler/stage_09_core/test_core_late_invariants.brp
	blorp/test/compiler/stage_09_core/test_core_match_projection.brp
	blorp/test/compiler/stage_09_core/test_core_perceus.brp
	blorp/test/compiler/stage_09_core/test_core_pipeline.brp
	blorp/test/compiler/stage_09_core/test_core_prepare.brp
	blorp/test/compiler/stage_09_core/test_core_resource.brp
	blorp/test/compiler/stage_09_core/test_core_reuse.brp
	blorp/test/compiler/stage_09_core/test_core_static_string_literals.brp
	blorp/test/compiler/stage_10_backend/test_static_string_literal_pool.brp
)
for root in "${required_core_sanitize_roots[@]}"; do
	if ! grep -Fxq "$root" scripts/compiler-core-sanitize-roots.txt; then
		echo "FAIL: compiler Core sanitizer manifest is missing required root: $root"
		exit 1
	fi
done

expected_default_gates='default_gates=(compiler_blorp runtime leak doctest cli)'
if ! grep -Fq "$expected_default_gates" scripts/test; then
	echo "FAIL: scripts/test defaults should exercise only Blorp-owned compiler suites"
	exit 1
fi
if ! grep -Fq 'bin/blorp test --doc --std-dir "$std_root"' scripts/test || \
	! grep -Fq -- '--timeout "$test_timeout" "$std_root"' scripts/test
then
	echo "FAIL: scripts/test doctest must use the explicit production std root"
	exit 1
fi

TMP_HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/blorp_script_harness.XXXXXX") || exit 1
trap 'rm -rf "$TMP_HARNESS"' EXIT

mkdir -p \
	"$TMP_HARNESS/bin" \
	"$TMP_HARNESS/scripts" \
	"$TMP_HARNESS/blorp/test/cli" \
	"$TMP_HARNESS/blorp/test/package" \
	"$TMP_HARNESS/blorp/test/lib" \
	"$TMP_HARNESS/blorp/test/tool" \
	"$TMP_HARNESS/standard_library/src" \
	"$TMP_HARNESS/standard_library/test" \
	"$TMP_HARNESS/blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass" \
	"$TMP_HARNESS/blorp/test/runtime/memory" \
	"$TMP_HARNESS/blorp/test/runtime/types"
: > "$TMP_HARNESS/blorp/test/runtime/memory/test_memory.brp"
: > "$TMP_HARNESS/blorp/test/runtime/types/test_type.brp"
cp scripts/test "$TMP_HARNESS/scripts/test"
cp scripts/compiler-core-sanitize-roots.txt "$TMP_HARNESS/scripts/compiler-core-sanitize-roots.txt"
cp blorp/test/lib/run_blorp_check_fixtures.py \
	"$TMP_HARNESS/blorp/test/lib/run_blorp_check_fixtures.py"
cp blorp/test/lib/process_supervisor.py \
	"$TMP_HARNESS/blorp/test/lib/process_supervisor.py"
cat > "$TMP_HARNESS/blorp/test/tool/test_compiler_tool_fixtures.py" <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import sys

Path("compiler-tool-command-log.txt").write_text(" ".join(sys.argv[1:]), encoding="utf-8")
gate = sys.argv[sys.argv.index("--gate-name") + 1]
print(f"BLORP_GATE_RESULT gate={gate} status=PASS passed=3 failed=0 tests=3")
PY
expected_blorp_check_fixture_count=56
for fixture_number in $(seq 1 "$expected_blorp_check_fixture_count"); do
	printf '%s\n' '-- RUN-BLORP-CHECK' \
		'func main(args: List[String]) -> Int: 0' \
		> "$TMP_HARNESS/blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/production_check_${fixture_number}.brp"
done

cat > "$TMP_HARNESS/blorp/test/cli/test_cli.sh" <<'SH'
#!/usr/bin/env bash
gate="cli"
printf '%s\n' "$*" > cli-command-log.txt
while [ $# -gt 0 ]; do
	if [ "$1" = "--gate-name" ] && [ $# -gt 1 ]; then
		gate="$2"
		shift 2
	else
		shift
	fi
done
echo "Results: 1 passed, 0 failed (1 CLI checks)"
echo "BLORP_GATE_RESULT gate=$gate status=PASS passed=1 failed=0 tests=1"
SH
chmod +x "$TMP_HARNESS/blorp/test/cli/test_cli.sh"

cat > "$TMP_HARNESS/blorp/test/package/test_package.sh" <<'SH'
#!/usr/bin/env bash
gate="package"
printf 'test_package.sh %s\n' "$*" > package-command-log.txt
while [ $# -gt 0 ]; do
	if [ "$1" = "--gate-name" ] && [ $# -gt 1 ]; then
		gate="$2"
		shift 2
	else
		shift
	fi
done
echo "Results: 1 passed, 0 failed (1 package checks)"
echo "BLORP_GATE_RESULT gate=$gate status=PASS passed=1 failed=0 tests=1"
SH
chmod +x "$TMP_HARNESS/blorp/test/package/test_package.sh"

cat > "$TMP_HARNESS/blorp/test/runtime/test_leak_report.sh" <<'SH'
#!/usr/bin/env bash
echo "Diagnostic results: 1 passed, 0 failed"
SH
chmod +x "$TMP_HARNESS/blorp/test/runtime/test_leak_report.sh"

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

cat > "$TMP_HARNESS/standard_library/src/prelude.brp" <<'BRP'
func main(args: List[String]) -> Int:
	0
BRP

write_fake_blorp() {
	local fake_check_log="$1"
	cat > "$TMP_HARNESS/bin/blorp" <<SH
#!/usr/bin/env bash
set -u

if [ "\${1:-}" = "check" ]; then
	echo "\$*" >> "$fake_check_log"
	exit 0
fi

if [ "\${1:-}" = "test" ]; then
	echo "\$*" >> "$TMP_HARNESS/test-command-log.txt"
	if [ -n "\${BLORP_TEST_FAILURE_OUTPUT:-}" ]; then
		for progress_line in {1..45}; do
			echo "test progress \$progress_line"
		done
		echo "  [FAIL] \$BLORP_TEST_FAILURE_OUTPUT"
	fi
	if [ -n "\${BLORP_TEST_TERMINAL_OUTPUT:-}" ]; then
		if [ -n "\${BLORP_TEST_EARLY_WARNING:-}" ]; then
			echo "Warning: \$BLORP_TEST_EARLY_WARNING"
		fi
		for progress_line in {1..45}; do
			echo "test progress \$progress_line"
		done
		echo "\$BLORP_TEST_TERMINAL_OUTPUT"
	fi
	echo "Results: 1 passed, 0 failed (1 tests)"
	if [ -n "\${BLORP_GATE_RESULT:-}" ]; then
		echo "BLORP_GATE_RESULT gate=\$BLORP_GATE_RESULT status=\${BLORP_TEST_RESULT_STATUS:-PASS} passed=\${BLORP_TEST_RESULT_PASSED:-1} failed=\${BLORP_TEST_RESULT_FAILED:-0} tests=\${BLORP_TEST_RESULT_TESTS:-1}"
	fi
	exit "\${BLORP_TEST_COMMAND_EXIT:-1}"
fi

echo "unexpected fake blorp command: \$*" >&2
exit 2
SH
	chmod +x "$TMP_HARNESS/bin/blorp"
}

output_file="$TMP_HARNESS/output.txt"
check_log="$TMP_HARNESS/check-log.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
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

assert_invalid_structured_result() {
	local name="$1"
	local result_status="$2"
	local passed="$3"
	local failed="$4"
	local tests="$5"
	local invalid_output="$TMP_HARNESS/invalid-$name-output.txt"
	local invalid_status

	(
		cd "$TMP_HARNESS" || exit 1
		BLORP_TEST_LOCK_HELD=1 \
			BLORP_TEST_COMMAND_EXIT=0 \
			BLORP_TEST_RESULT_STATUS="$result_status" \
			BLORP_TEST_RESULT_PASSED="$passed" \
			BLORP_TEST_RESULT_FAILED="$failed" \
			BLORP_TEST_RESULT_TESTS="$tests" \
			bash scripts/test runtime --serial
	) > "$invalid_output" 2>&1
	invalid_status=$?

	if [ "$invalid_status" -eq 0 ] ||
		! grep -Eq 'Runtime[[:space:]]+FAIL[[:space:]]+0[[:space:]]+1[[:space:]]+1' \
			"$invalid_output" ||
		! grep -Fq 'runtime gate reported an invalid structured result' \
			"$invalid_output"
	then
		echo "FAIL: scripts/test accepted invalid structured result: $name"
		cat "$invalid_output"
		exit 1
	fi
}

assert_invalid_structured_result contradictory-pass PASS 0 1 1
assert_invalid_structured_result nonnumeric-count PASS nope 0 1
assert_invalid_structured_result inconsistent-total FAIL 1 1 1
assert_invalid_structured_result oversized-count PASS 999999999999999999999999 0 999999999999999999999999

echo "PASS: scripts/test rejects invalid structured gate results"

named_failure_output="$TMP_HARNESS/named-failure-output.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_COMMAND_EXIT=1 \
		BLORP_TEST_RESULT_STATUS=FAIL \
		BLORP_TEST_RESULT_PASSED=0 \
		BLORP_TEST_RESULT_FAILED=1 \
		BLORP_TEST_FAILURE_OUTPUT='late named failure' \
		bash scripts/test runtime --serial
) > "$named_failure_output" 2>&1
named_failure_status=$?

named_failure_excerpt=$(sed -n '/^Failure output for runtime:/,/^Re-run with --verbose/p' \
	"$named_failure_output")
if [ "$named_failure_status" -eq 0 ] \
	|| ! grep -Fq '[FAIL] late named failure' <<< "$named_failure_excerpt"
then
	echo "FAIL: scripts/test should include indented test failures in its compact excerpt"
	cat "$named_failure_output"
	exit 1
fi

echo "PASS: scripts/test preserves indented test failures in compact excerpts"

terminal_failure_output="$TMP_HARNESS/terminal-failure-output.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_COMMAND_EXIT=1 \
		BLORP_TEST_RESULT_STATUS=FAIL \
		BLORP_TEST_RESULT_PASSED=0 \
		BLORP_TEST_RESULT_FAILED=1 \
		BLORP_TEST_EARLY_WARNING='non-terminal setup warning' \
		BLORP_TEST_TERMINAL_OUTPUT='native compiler exceeded its artifact budget' \
		bash scripts/test runtime --serial
) > "$terminal_failure_output" 2>&1
terminal_failure_status=$?

terminal_failure_excerpt=$(sed -n '/^Failure output for runtime:/,/^Re-run with --verbose/p' \
	"$terminal_failure_output")
if [ "$terminal_failure_status" -eq 0 ] \
	|| ! grep -Fq 'non-terminal setup warning' <<< "$terminal_failure_excerpt" \
	|| ! grep -Fq 'native compiler exceeded its artifact budget' <<< "$terminal_failure_excerpt"
then
	echo "FAIL: scripts/test should show terminal diagnostics after earlier warning markers"
	cat "$terminal_failure_output"
	exit 1
fi

echo "PASS: scripts/test preserves warning and terminal diagnostics in compact excerpts"

rm -f "$TMP_HARNESS/make-target-log.txt"
no_build_output="$TMP_HARNESS/no-build-output.txt"
forbidden_toolchain_bin="$TMP_HARNESS/forbidden-toolchain-bin"
mkdir -p "$forbidden_toolchain_bin"
for tool in opam dune ocaml; do
	cat > "$forbidden_toolchain_bin/$tool" <<SH
#!/usr/bin/env bash
echo "unexpected $tool invocation in prebuilt test lane" >&2
exit 97
SH
	chmod +x "$forbidden_toolchain_bin/$tool"
done
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	PATH="$forbidden_toolchain_bin:$PATH" \
		BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_COMMAND_EXIT=0 \
		BLORP_TEST_TIMEOUT=30 \
		BLORP_RUNTIME_TEST_TIMEOUT=60 \
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

echo "PASS: scripts/test can test a prebuilt toolchain without external compiler tooling"

if ! grep -Fxq 'test --suite --timeout 60 blorp/test/runtime/types/' "$TMP_HARNESS/test-command-log.txt"; then
	echo "FAIL: scripts/test runtime should enumerate non-leak-owned sources"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

if grep -Fq 'blorp/test/runtime/memory' "$TMP_HARNESS/test-command-log.txt" \
	|| grep -Fq 'blorp/test/runtime/sys/test_file_resource.brp' "$TMP_HARNESS/test-command-log.txt"; then
	echo "FAIL: scripts/test runtime should leave leak-owned sources to the leak gate"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

echo "PASS: scripts/test runtime leaves leak-owned sources to the leak gate"

varied_root_index=0
while [ "$varied_root_index" -lt 65 ]; do
	mkdir -p "$TMP_HARNESS/blorp/test/runtime/runtime_group_$varied_root_index"
	varied_root_index=$((varied_root_index + 1))
done
: > "$TMP_HARNESS/test-command-log.txt"
single_runtime_output="$TMP_HARNESS/single-runtime-output.txt"
write_fake_blorp "$check_log"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_COMMAND_EXIT=0 \
		bash scripts/test runtime --serial --no-build
) > "$single_runtime_output" 2>&1
single_runtime_status=$?

if [ "$single_runtime_status" -ne 0 ] \
	|| ! grep -Eq 'Runtime[[:space:]]+PASS[[:space:]]+1[[:space:]]+0[[:space:]]+1' \
		"$single_runtime_output" \
	|| [ "$(wc -l < "$TMP_HARNESS/test-command-log.txt" | tr -d ' ')" -ne 1 ]
then
	echo "FAIL: scripts/test runtime should compile all selected roots once"
	cat "$single_runtime_output"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

echo "PASS: scripts/test compiles all selected runtime roots once"

leak_output_file="$TMP_HARNESS/leak-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		BLORP_TEST_COMMAND_EXIT=0 \
		BLORP_TEST_TIMEOUT=30 \
		BLORP_LEAK_TEST_TIMEOUT=60 \
		bash scripts/test leak --serial --no-build --verbose
) > "$leak_output_file" 2>&1
leak_status=$?

if [ "$leak_status" -ne 0 ]; then
	echo "FAIL: scripts/test leak should run the focused memory corpus"
	cat "$leak_output_file"
	exit 1
fi

if ! grep -Fq 'test --leak-check --suite --timeout 60 blorp/test/runtime/memory/' "$TMP_HARNESS/test-command-log.txt" \
	|| ! grep -Fq 'blorp/test/compiler/pipeline/test_type_header_graph.brp' "$TMP_HARNESS/test-command-log.txt" \
	|| ! grep -Fq 'blorp/test/runtime/sys/test_file_resource.brp' "$TMP_HARNESS/test-command-log.txt"
then
	echo "FAIL: scripts/test leak should retain curated ownership regressions"
	cat "$TMP_HARNESS/test-command-log.txt"
	exit 1
fi

echo "PASS: scripts/test leak owns dedicated and curated ownership regressions"

if ! grep -Fxq 'Diagnostic results: 1 passed, 0 failed' "$leak_output_file" \
	|| ! grep -Fxq 'Results: 2 passed, 0 failed (2 leak checks)' "$leak_output_file"
then
	echo "FAIL: scripts/test leak should distinguish its diagnostic subtotal from the combined result"
	cat "$leak_output_file"
	exit 1
fi

echo "PASS: scripts/test leak reports an unambiguous combined result"

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

expected_std_root=$(CDPATH= cd -- "$TMP_HARNESS/standard_library/src" && pwd -P)
if ! grep -Fxq "check --no-format --std-dir $expected_std_root $expected_std_root" "$std_check_log"; then
	echo "FAIL: scripts/test std-check should check std with explicit stdlib context"
	cat "$std_check_output_file"
	cat "$std_check_log"
	exit 1
fi

echo "PASS: scripts/test std-check is explicit"

package_output_file="$TMP_HARNESS/package-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test package --serial
) > "$package_output_file" 2>&1
package_status=$?

if [ "$package_status" -ne 0 ]; then
	echo "FAIL: scripts/test package should run as an explicit gate"
	cat "$package_output_file"
	exit 1
fi

if ! grep -Fq -- 'test_package.sh --timeout 30 --gate-name package' \
	"$TMP_HARNESS/package-command-log.txt"; then
	echo "FAIL: package gate should select focused package integration checks"
	cat "$package_output_file"
	exit 1
fi

if ! grep -Eq 'Package[[:space:]]+PASS' "$package_output_file"; then
	echo "FAIL: scripts/test should render the package gate"
	cat "$package_output_file"
	exit 1
fi

echo "PASS: scripts/test exposes focused package integration checks"

if grep -Fq -- '--package' blorp/test/cli/test_cli.sh ||
	grep -Fq 'package check success' blorp/test/cli/test_cli.sh ||
	grep -Fq 'test_cli.sh --package' blorp/test/package/test_package.sh
then
	echo "FAIL: package lifecycle checks must be implemented by the package test owner"
	exit 1
fi

if ! grep -Fq 'package check success' blorp/test/package/test_package.sh; then
	echo "FAIL: package test owner should contain package lifecycle assertions"
	exit 1
fi

echo "PASS: package lifecycle checks have a package-owned implementation"

mkdir -p "$TMP_HARNESS/blorp/test/lsp/fixtures" "$TMP_HARNESS/fake-python-bin"
cat > "$TMP_HARNESS/fake-python-bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_LSP_FAIL:-0}" = "1" ]; then
	echo "FAIL: public LSP fixture regression"
	echo "BLORP_GATE_RESULT gate=${BLORP_GATE_RESULT:-lsp} status=FAIL passed=11 failed=1 tests=12"
	exit 1
fi
echo "BLORP_GATE_RESULT gate=${BLORP_GATE_RESULT:-lsp} status=PASS passed=12 failed=0 tests=12"
SH
chmod +x "$TMP_HARNESS/fake-python-bin/python3"
lsp_failure_output="$TMP_HARNESS/lsp-failure-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		FAKE_LSP_FAIL=1 \
		PATH="$TMP_HARNESS/fake-python-bin:$PATH" \
		bash scripts/test lsp --serial
) > "$lsp_failure_output" 2>&1
lsp_failure_status=$?

if [ "$lsp_failure_status" -eq 0 ]; then
	echo "FAIL: scripts/test lsp should propagate fixture failures"
	cat "$lsp_failure_output"
	exit 1
fi
if ! grep -Eq 'LSP[[:space:]]+FAIL[[:space:]]+11[[:space:]]+1[[:space:]]+12' \
	"$lsp_failure_output" ||
	! grep -Fq 'public LSP fixture regression' "$lsp_failure_output"
then
	echo "FAIL: scripts/test lsp should preserve structured counts and failure names"
	cat "$lsp_failure_output"
	exit 1
fi

echo "PASS: scripts/test preserves LSP failure counts and names"

parallel_gate_output="$TMP_HARNESS/parallel-gate-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		PATH="$TMP_HARNESS/fake-python-bin:$PATH" \
		bash scripts/test lsp package
) > "$parallel_gate_output" 2>&1
parallel_gate_status=$?

if [ "$parallel_gate_status" -ne 0 ] \
	|| ! grep -Eq 'LSP[[:space:]]+PASS[[:space:]]+12[[:space:]]+0[[:space:]]+12' \
		"$parallel_gate_output" \
	|| ! grep -Eq 'Package[[:space:]]+PASS' "$parallel_gate_output"
then
	echo "FAIL: parallel LSP/package worker collection should preserve both gates"
	cat "$parallel_gate_output"
	exit 1
fi

echo "PASS: scripts/test collects LSP and package parallel workers"

mkdir -p "$TMP_HARNESS/blorp/test/compiler"
for source_number in 01 02 03 04 05 06 07; do
	: > "$TMP_HARNESS/blorp/test/compiler/test_${source_number}.brp"
done
mkdir -p "$TMP_HARNESS/blorp/test/lsp/analysis"
: > "$TMP_HARNESS/blorp/test/lsp/analysis/test_08.brp"
cat > "$TMP_HARNESS/blorp/test/compiler/compiler_test_ownership.json" <<'JSON'
{
  "suites": [
    {"path": "blorp/test/compiler/test_01.brp"},
    {"path": "blorp/test/compiler/test_02.brp"},
    {"path": "blorp/test/compiler/test_03.brp"},
    {"path": "blorp/test/compiler/test_04.brp"},
    {"path": "blorp/test/compiler/test_05.brp"},
    {"path": "blorp/test/compiler/test_06.brp"},
    {"path": "blorp/test/compiler/test_07.brp"},
    {"path": "blorp/test/lsp/analysis/test_08.brp"}
  ]
}
JSON
compiler_blorp_sanitize_log="$TMP_HARNESS/compiler-blorp-sanitize-log.txt"
cat > "$TMP_HARNESS/bin/blorp" <<SH
#!/usr/bin/env bash
set -u

if [ "\${1:-}" = "check" ]; then
	exit 0
fi

	if [ "\${1:-}" = "test" ]; then
	echo "\$*" >> "$compiler_blorp_sanitize_log"
	if [ "\${BLORP_TEST_EMIT_ARTIFACT_PROGRESS:-0}" = "1" ]; then
		echo "BLORP_TEST_ARTIFACT_START kind=suite sources=2 timeout_seconds=360"
		echo "BLORP_TEST_ARTIFACT_SOURCE blorp/test/compiler/test_04.brp"
		echo "BLORP_TEST_ARTIFACT_SOURCE blorp/test/compiler/test_05.brp"
		echo "BLORP_TEST_ARTIFACT_RESULT passed=1 failed=0 tests=1"
		echo "BLORP_TEST_ARTIFACT_END kind=suite sources=2 duration_ms=1250"
	fi
	echo "Results: 1 passed, 0 failed (1 tests)"
	echo "BLORP_GATE_RESULT gate=\${BLORP_GATE_RESULT:-missing} status=PASS passed=1 failed=0 tests=1"
	exit 0
fi

echo "unexpected fake blorp command: \$*" >&2
exit 2
SH
chmod +x "$TMP_HARNESS/bin/blorp"

compiler_blorp_sanitize_output="$TMP_HARNESS/compiler-blorp-sanitize-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test compiler-blorp-sanitize --serial
) > "$compiler_blorp_sanitize_output" 2>&1
compiler_blorp_sanitize_status=$?

if [ "$compiler_blorp_sanitize_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-blorp-sanitize should run as an explicit gate"
	cat "$compiler_blorp_sanitize_output"
	exit 1
fi

expected_compiler_sanitize_timeout=180
expected_blorp_sanitize_command="test --sanitize --timeout $expected_compiler_sanitize_timeout blorp/test/compiler/"
if ! grep -Fxq "$expected_blorp_sanitize_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-blorp-sanitize should use the sanitized test route"
	cat "$compiler_blorp_sanitize_output"
	cat "$compiler_blorp_sanitize_log"
	exit 1
fi

if ! grep -Eq 'Compiler-Blorp-ASan[[:space:]]+PASS' "$compiler_blorp_sanitize_output"; then
	echo "FAIL: scripts/test should render the compiler Blorp sanitizer gate"
	cat "$compiler_blorp_sanitize_output"
	exit 1
fi

echo "PASS: scripts/test exposes a compiler Blorp sanitizer gate"

: > "$compiler_blorp_sanitize_log"
compiler_blorp_explicit_output="$TMP_HARNESS/compiler-blorp-explicit-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test compiler-blorp --serial
) > "$compiler_blorp_explicit_output" 2>&1
compiler_blorp_explicit_status=$?

if [ "$compiler_blorp_explicit_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-blorp should run as an explicit gate"
	cat "$compiler_blorp_explicit_output"
	exit 1
fi

expected_compiler_blorp_timeout=360
expected_blorp_command="test --suite --timeout $expected_compiler_blorp_timeout blorp/test/compiler/test_01.brp blorp/test/compiler/test_02.brp blorp/test/compiler/test_03.brp blorp/test/compiler/test_04.brp blorp/test/compiler/test_05.brp blorp/test/compiler/test_06.brp blorp/test/compiler/test_07.brp blorp/test/lsp/analysis/test_08.brp"
if ! grep -Fxq "$expected_blorp_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-blorp should run every manifest-owned TestSuite once"
	cat "$compiler_blorp_explicit_output"
	cat "$compiler_blorp_sanitize_log"
	exit 1
fi

expected_compiler_blorp_total=$((expected_blorp_check_fixture_count + 1))
if ! grep -Eq "Compiler-Blorp[[:space:]]+PASS[[:space:]]+$expected_compiler_blorp_total[[:space:]]+0[[:space:]]+$expected_compiler_blorp_total" "$compiler_blorp_explicit_output"; then
	echo "FAIL: scripts/test should aggregate Blorp TestSuites and production check fixtures"
	cat "$compiler_blorp_explicit_output"
	exit 1
fi

echo "PASS: scripts/test exposes compiler-owned Blorp suites as an explicit gate"

python3 - "$TMP_HARNESS/blorp/test/compiler/compiler_test_ownership.json" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
manifest = json.loads(path.read_text())
manifest["suites"].append({"path": "blorp/test/compiler/missing.brp"})
path.write_text(json.dumps(manifest))
PY
compiler_blorp_missing_output="$TMP_HARNESS/compiler-blorp-missing-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test compiler-blorp --serial
) > "$compiler_blorp_missing_output" 2>&1
compiler_blorp_missing_status=$?

if [ "$compiler_blorp_missing_status" -eq 0 ] \
	|| ! grep -Fq 'Error: compiler test suite does not exist: blorp/test/compiler/missing.brp' \
		"$compiler_blorp_missing_output"
then
	echo "FAIL: compiler-blorp should reject a stale manifest suite before compilation"
	cat "$compiler_blorp_missing_output"
	exit 1
fi

echo "PASS: scripts/test rejects stale compiler suite inventory"

compiler_tools_output="$TMP_HARNESS/compiler-tools-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test compiler-tools --serial
) > "$compiler_tools_output" 2>&1
compiler_tools_status=$?

if [ "$compiler_tools_status" -ne 0 ] ||
	! grep -Eq 'Compiler-Tools[[:space:]]+PASS[[:space:]]+3[[:space:]]+0[[:space:]]+3' \
		"$compiler_tools_output"
then
	echo "FAIL: scripts/test compiler-tools should preserve public tool fixtures"
	cat "$compiler_tools_output"
	exit 1
fi
if ! grep -Fq -- '--timeout 360 --gate-name compiler_tools' \
	"$TMP_HARNESS/compiler-tool-command-log.txt"
then
	echo "FAIL: compiler-tools should enforce its measured timeout"
	cat "$TMP_HARNESS/compiler-tool-command-log.txt"
	exit 1
fi

echo "PASS: scripts/test exposes public compiler tool fixtures as an explicit gate"

: > "$compiler_blorp_sanitize_log"
compiler_core_sanitize_output="$TMP_HARNESS/compiler-core-sanitize-output.txt"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test compiler-core-sanitize --serial
) > "$compiler_core_sanitize_output" 2>&1
compiler_core_sanitize_status=$?

if [ "$compiler_core_sanitize_status" -ne 0 ]; then
	echo "FAIL: scripts/test compiler-core-sanitize should run as an explicit gate"
	cat "$compiler_core_sanitize_output"
	exit 1
fi

expected_core_sanitize_prefix="test --sanitize --timeout $expected_compiler_sanitize_timeout"
expected_core_sanitize_roots=$(tr '\n' ' ' < scripts/compiler-core-sanitize-roots.txt)
expected_core_sanitize_roots=${expected_core_sanitize_roots% }
expected_core_sanitize_command="$expected_core_sanitize_prefix $expected_core_sanitize_roots"
if ! grep -Fxq "$expected_core_sanitize_command" "$compiler_blorp_sanitize_log"; then
	echo "FAIL: compiler-core-sanitize should use the explicit serial Core file set"
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

mkdir -p "$TMP_HARNESS/blorp/test/compiler"
cat > "$TMP_HARNESS/bin/blorp" <<'SH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = "test" ]; then
	if [ "${BLORP_TEST_TIMINGS:-}" != "1" ]; then
		echo "missing BLORP_TEST_TIMINGS" >&2
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
chmod +x "$TMP_HARNESS/bin/blorp"

generated_timing_output_file="$TMP_HARNESS/generated-timing-output.txt"
generated_timing_log_dir="$TMP_HARNESS/generated-timing-logs"
(
	cd "$TMP_HARNESS" || exit 1
	BLORP_TEST_LOCK_HELD=1 \
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
