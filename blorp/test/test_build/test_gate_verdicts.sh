#!/usr/bin/env bash
# scripts/test must never report PASS for a gate that failed, printed no
# verdict, or was interrupted. Runs the doctest gate (the one that needs no
# fixtures) against a fake bin/blorp in a scratch directory; takes seconds.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/blorp_gate_verdicts.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/scripts" "$SCRATCH/standard_library/src"
: > "$SCRATCH/scripts/compiler-core-sanitize-roots.txt"
: > "$SCRATCH/scripts/compiler-tools-python-tests.txt"
cp "$ROOT/scripts/test" "$SCRATCH/scripts/test"
printf 'all install build:\n\t@true\n' > "$SCRATCH/Makefile"
# FAKE_BLORP_MODE picks how the fake compiler's `test` run ends.
cat > "$SCRATCH/bin/blorp" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" = "--warmup-only" ] && exit 0
gate="${BLORP_GATE_RESULT:-test}"
case "${FAKE_BLORP_MODE:-pass}" in
	pass) echo "BLORP_GATE_RESULT gate=$gate status=PASS passed=1 failed=0 tests=1" ;;
	fail) echo "BLORP_GATE_RESULT gate=$gate status=FAIL passed=0 failed=1 tests=1"; exit 1 ;;
	silent) echo "ran without printing a verdict" ;;
	hang) echo $$ > "$FAKE_BLORP_PID_FILE"; exec sleep 60 ;;
esac
SH
chmod +x "$SCRATCH/bin/blorp"

failures=0

# Runs the gate in the scratch directory; sets `status` and `output`.
run_gate() {
	output=$(cd "$SCRATCH" && FAKE_BLORP_MODE="$1" BLORP_TEST_LOCK_HELD=1 \
		bash scripts/test doctest --no-build --serial 2>&1)
	status=$?
}

expect() {
	local name="$1" want_status="$2" want_verdict="$3" status_ok=true
	case "$want_status" in
		zero) [ "$status" -eq 0 ] || status_ok=false ;;
		nonzero) [ "$status" -ne 0 ] || status_ok=false ;;
	esac
	if ! $status_ok \
		|| ! printf '%s\n' "$output" | grep -q "^BLORP_GATE_RESULT gate=test status=$want_verdict "
	then
		echo "FAIL: $name (exit $status, wanted $want_status exit and status=$want_verdict)"
		printf '%s\n' "$output" | tail -5
		failures=$((failures + 1))
	else
		echo "PASS: $name"
	fi
}

run_gate pass
expect "a passing gate reports PASS" zero PASS

run_gate fail
expect "a failing gate reports FAIL" nonzero FAIL

run_gate silent
expect "a gate with no verdict reports FAIL" nonzero FAIL

# Interrupt a gate whose test run hangs: the verdict must be FAIL, at once,
# and the fake compiler must not outlive the script.
# `exec` so that $! is scripts/test itself, not a wrapping subshell.
(cd "$SCRATCH" && FAKE_BLORP_MODE=hang FAKE_BLORP_PID_FILE="$SCRATCH/fake.pid" BLORP_TEST_LOCK_HELD=1 \
	exec bash scripts/test doctest --no-build --serial > "$SCRATCH/interrupted.txt" 2>&1) &
gate_pid=$!
sleep 2
kill -TERM "$gate_pid"
{ wait "$gate_pid"; } 2>/dev/null
status=$?
output=$(cat "$SCRATCH/interrupted.txt")
expect "an interrupted gate reports FAIL" nonzero FAIL
fake_pid=$(cat "$SCRATCH/fake.pid" 2>/dev/null || true)
if [ -n "$fake_pid" ] && kill -0 "$fake_pid" 2>/dev/null; then
	echo "FAIL: an interrupted gate left its test process running"
	kill -KILL "$fake_pid"
	failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
