#!/usr/bin/env bash
# Regression tests for the gate entry points' verdict line when a gate is
# interrupted. scripts/docker-gate, scripts/premerge-gate and scripts/test each
# print one `BLORP_GATE_RESULT gate=<name> status=... ` line last, with an exit
# status that agrees with it. A fatal signal must produce FAIL and a nonzero
# exit, and must do so promptly: a trap on the signal would wait for the
# foreground command (a `docker run`, a gate) to finish first.
#
# Each entry point runs from a sandbox copy against shims for `docker`, `make`,
# `sleep` and the gates it launches, so nothing here builds or tests Blorp.

set -u

cd "$(dirname "$0")/../../.."
REPO_ROOT=$(pwd)

# The most time a gate may take from receiving a signal to exiting.
SIGNAL_EXIT_LIMIT_POLLS=40
SIGNAL_EXIT_POLL_SECONDS=0.05
# The most time a test waits for a gate to reach the point it is interrupted at,
# and how long it lets the gate settle into that point before signalling.
REACH_LIMIT_POLLS=200
SETTLE_SECONDS=0.3

REAL_SLEEP=$(command -v sleep)
HAVE_PERL=no
command -v perl >/dev/null 2>&1 && HAVE_PERL=yes
TMP_HARNESS=$(mktemp -d "${TMPDIR:-/tmp}/blorp_gate_interrupt.XXXXXX") || exit 1
FAKE_PIDS="$TMP_HARNESS/fake-pids"
: > "$FAKE_PIDS"

cleanup() {
	# Only processes the shims below started and recorded.
	local pid
	while IFS= read -r pid; do
		# A recorded pid may have exited and been reused; only stop a process
		# that is still one of the shims' own: a script under the harness
		# directory, or the shims' long `sleep 120`.
		case "$(ps -o command= -p "$pid" 2>/dev/null)" in
			*"$TMP_HARNESS"*|*"sleep 120") kill "$pid" 2>/dev/null ;;
		esac
	done < "$FAKE_PIDS"
	rm -rf "$TMP_HARNESS"
}
trap cleanup EXIT

failures=0
fail() {
	echo "FAIL: $1"
	failures=$((failures + 1))
}

# --- Sandbox -----------------------------------------------------------------

SANDBOX="$TMP_HARNESS/repo"
SHIMS="$TMP_HARNESS/shims"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/bin" "$SANDBOX/blorp/test/cli" "$SANDBOX/blorp/test/package" \
	"$SANDBOX/blorp/test/compiler/pipeline/codegen_audit" "$SHIMS" \
	"$TMP_HARNESS/tmp"
cp scripts/docker-gate scripts/premerge-gate scripts/test \
	scripts/compiler-core-sanitize-roots.txt scripts/compiler-tools-python-tests.txt \
	"$SANDBOX/scripts/"
(cd "$SANDBOX" && git init -q .)

# Records its pid, then becomes `sleep`, so the harness can stop it by pid.
cat > "$SHIMS/sleep" <<SH
#!/bin/bash
echo \$\$ >> "$FAKE_PIDS"
exec "$REAL_SLEEP" "\$@"
SH

# A fifo for builtin-only timed waits: `read -t` on it blocks without a child
# process, so a signal kills the waiting shell itself, as it would a docker
# client or a gate that has not yet printed its verdict.
SLOW_GATE_SECONDS=2
mkfifo "$TMP_HARNESS/slow.fifo"

# Fake docker. FAKE_DOCKER_RUN picks what `docker run` does: hang, wait
# SLOW_GATE_SECONDS and then behave normally (slow), or print a
# nested verdict (FAKE_DOCKER_VERDICT; empty prints none) and exit
# FAKE_DOCKER_EXIT. Each run logs "start LABEL" and, if it finishes, "end LABEL"
# to docker-run.events, so tests can see which gates ran at once. `docker info
# --format` reports FAKE_DOCKER_NCPU CPUs.
cat > "$SHIMS/docker" <<SH
#!/bin/bash
case "\$1" in
	info)
		[ "\${2:-}" != --format ] || echo "\${FAKE_DOCKER_NCPU:-8}"
		exit 0
		;;
	image) exit 0 ;;
	run)
		echo "start \${FAKE_DOCKER_LABEL:-run}" >> "$TMP_HARNESS/docker-run.events"
		if [ "\${FAKE_DOCKER_RUN:-}" = hang ]; then
			echo "container started"
			echo \$\$ | tee -a "$FAKE_PIDS" > "$TMP_HARNESS/running-gate.pid"
			exec "$REAL_SLEEP" 120
		fi
		if [ "\${FAKE_DOCKER_RUN:-}" = slow ]; then
			echo "container started"
			echo \$\$ | tee -a "$FAKE_PIDS" > "$TMP_HARNESS/running-gate.pid"
			exec 3<> "$TMP_HARNESS/slow.fifo"
			read -t \${FAKE_DOCKER_SLOW_SECONDS:-$SLOW_GATE_SECONDS} -u 3 || true
		fi
		echo "\$*" > "$TMP_HARNESS/docker-run.args"
		echo "end \${FAKE_DOCKER_LABEL:-run}" >> "$TMP_HARNESS/docker-run.events"
		echo "container output"
		[ -z "\${FAKE_DOCKER_VERDICT:-}" ] || echo "\$FAKE_DOCKER_VERDICT"
		exit "\${FAKE_DOCKER_EXIT:-0}"
		;;
esac
exit 0
SH

# `make` and the codegen audit succeed without doing anything.
printf '#!/bin/bash\nexit 0\n' > "$SHIMS/make"
printf '#!/bin/bash\nexit 0\n' > "$SANDBOX/bin/blorp"
printf '#!/bin/bash\nexit 0\n' \
	> "$SANDBOX/blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh"

# The gate scripts/premerge-gate and scripts/test launch. FAKE_GATE_RUN=hang
# blocks it; FAKE_GATE_VERDICT overrides the default verdict, including with
# an empty string to simulate a successful gate that reports no result.
cat > "$SANDBOX/scripts/fake-gate-body" <<SH
if [ "\${FAKE_GATE_RUN:-}" = hang ]; then
	echo "gate started"
	echo \$\$ | tee -a "$FAKE_PIDS" > "$TMP_HARNESS/running-gate.pid"
	exec "$REAL_SLEEP" 120
fi
if [ "\${FAKE_GATE_RUN:-}" = slow ]; then
	echo "gate started"
	echo \$\$ | tee -a "$FAKE_PIDS" > "$TMP_HARNESS/running-gate.pid"
	exec 3<> "$TMP_HARNESS/slow.fifo"
	read -t $SLOW_GATE_SECONDS -u 3 || true
fi
SH
cat > "$SANDBOX/scripts/test.fake" <<SH
#!/bin/bash
. "$SANDBOX/scripts/fake-gate-body"
if [ "\${FAKE_GATE_VERDICT+x}" = x ]; then
	[ -z "\$FAKE_GATE_VERDICT" ] || printf '%s\n' "\$FAKE_GATE_VERDICT"
else
	echo "BLORP_GATE_RESULT gate=test status=\${FAKE_GATE_STATUS:-PASS} passed=4 failed=0 tests=4"
fi
SH
cat > "$SANDBOX/blorp/test/cli/test_cli.sh" <<SH
#!/bin/bash
. "$SANDBOX/scripts/fake-gate-body"
echo "Results: 1 passed, 0 failed (1 CLI checks)"
echo "BLORP_GATE_RESULT gate=cli status=PASS passed=1 failed=0 tests=1"
SH
cat > "$SANDBOX/blorp/test/package/test_package.sh" <<SH
#!/bin/bash
echo "Results: 1 passed, 0 failed (1 package checks)"
echo "BLORP_GATE_RESULT gate=package status=PASS passed=1 failed=0 tests=1"
SH
chmod +x "$SANDBOX/blorp/test/package/test_package.sh" "$SHIMS"/* "$SANDBOX/bin/blorp" "$SANDBOX/scripts/test.fake" \
	"$SANDBOX/blorp/test/cli/test_cli.sh" \
	"$SANDBOX/blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh"

# --- Running -----------------------------------------------------------------

# run_gate NAME SIGNAL REACHED_PATTERN COMMAND [ARG...]
#
# Starts the command in the sandbox with the shims first on PATH and its output
# in $TMP_HARNESS/NAME.out. With SIGNAL "none", waits for it to finish. Else
# waits for REACHED_PATTERN to appear in the output, sends SIGNAL to the
# command's own pid, and times how long it takes to exit. Sets run_status,
# run_signal_polls and run_last_line; run_output holds the whole output.
# start_gate NAME SIGNAL COMMAND [ARG...]: the launch half of run_gate. Sets
# START_PID to the command's pid; the exit status lands in NAME.status.
start_gate() {
	local name="$1" signal="$2"
	shift 2
	local out="$TMP_HARNESS/$name.out" pid_file="$TMP_HARNESS/$name.pid"
	local status_file="$TMP_HARNESS/$name.status"
	rm -f "$status_file" "$pid_file"
	: > "$out"
	# A terminal sends Ctrl-C to the whole foreground process group, so SIGINT
	# runs in a session of its own that the harness can signal as a group. A
	# lone SIGINT to the shell would leave it waiting for its foreground child.
	local launcher=()
	if [ "$signal" = INT ]; then
		launcher=(perl -e 'use POSIX qw(setsid); setsid(); $SIG{INT} = "DEFAULT"; exec @ARGV')
	fi
	(
		cd "$SANDBOX" || exit 1
		PATH="$SHIMS:$PATH" TMPDIR="$TMP_HARNESS/tmp" BLORP_TEST_LOCK_HELD=1 \
			FAKE_DOCKER_LABEL="$name" \
			bash -c 'echo $$ > "$1"; shift; exec "$@"' bash "$pid_file" \
			${launcher[@]+"${launcher[@]}"} "$@" > "$out" 2>&1
		echo $? > "$status_file"
	) 2>/dev/null &
	while [ ! -s "$pid_file" ]; do
		"$REAL_SLEEP" 0.05
	done
	START_PID=$(cat "$pid_file")
}

# wait_for_text NAME PATTERN: waits for PATTERN in NAME's output.
wait_for_text() {
	local name="$1" pattern="$2" waited=0
	while ! grep -q -- "$pattern" "$TMP_HARNESS/$name.out" && [ "$waited" -lt "$REACH_LIMIT_POLLS" ]; do
		"$REAL_SLEEP" 0.05
		waited=$((waited + 1))
	done
	if ! grep -q -- "$pattern" "$TMP_HARNESS/$name.out"; then
		fail "$name: never reached '$pattern'; output so far:"
		sed 's/^/    | /' "$TMP_HARNESS/$name.out"
	fi
}

# wait_for_exit NAME: waits for NAME to finish; its status is in wait_status.
wait_for_exit() {
	local name="$1" waited=0
	while [ ! -s "$TMP_HARNESS/$name.status" ] && [ "$waited" -lt "$REACH_LIMIT_POLLS" ]; do
		"$REAL_SLEEP" 0.1
		waited=$((waited + 1))
	done
	if [ ! -s "$TMP_HARNESS/$name.status" ]; then
		fail "$name: still running after the wait; stopping it"
		kill -KILL "$(cat "$TMP_HARNESS/$name.pid")" 2>/dev/null
		wait_status=-1
		return
	fi
	wait_status=$(cat "$TMP_HARNESS/$name.status")
}

run_gate() {
	local name="$1" signal="$2" reached="$3"
	shift 3
	local out="$TMP_HARNESS/$name.out"
	local status_file="$TMP_HARNESS/$name.status"
	local waited=0
	start_gate "$name" "$signal" "$@"
	local gate_pid="$START_PID"

	run_signal_polls=0
	if [ "$signal" != none ]; then
		wait_for_text "$name" "$reached"
		"$REAL_SLEEP" "$SETTLE_SECONDS"
		if [ "$signal" = INT ]; then
			kill -INT -- "-$gate_pid" 2>/dev/null
		else
			kill -"$signal" "$gate_pid" 2>/dev/null
		fi
		while [ ! -s "$status_file" ] && [ "$run_signal_polls" -lt "$SIGNAL_EXIT_LIMIT_POLLS" ]; do
			"$REAL_SLEEP" "$SIGNAL_EXIT_POLL_SECONDS"
			run_signal_polls=$((run_signal_polls + 1))
		done
		echo "  $name: exited within $((run_signal_polls * 50))ms of SIG$signal"
	else
		while [ ! -s "$status_file" ] && [ "$waited" -lt "$REACH_LIMIT_POLLS" ]; do
			"$REAL_SLEEP" 0.1
			waited=$((waited + 1))
		done
	fi
	if [ ! -s "$status_file" ]; then
		fail "$name: still running after the wait; stopping it"
		kill -KILL "$gate_pid" 2>/dev/null
		"$REAL_SLEEP" 0.2
		run_status=-1
	else
		run_status=$(cat "$status_file")
	fi
	run_output=$(cat "$out")
	run_last_line=$(tail -1 "$out")
}

# expect_verdict NAME GATE STATUS EXIT_ZERO(yes|no)
expect_verdict() {
	local name="$1" gate="$2" status="$3" zero="$4"
	local failures_before="$failures" verdict_count count_pattern
	verdict_count=$(grep -c "^BLORP_GATE_RESULT gate=$gate " <<<"$run_output")
	if [ "$verdict_count" -ne 1 ]; then
		fail "$name: expected exactly one gate=$gate verdict line, found $verdict_count"
	fi
	case "$run_last_line" in
		"BLORP_GATE_RESULT gate=$gate status=$status "*) ;;
		*) fail "$name: last line should be a gate=$gate status=$status verdict, got: $run_last_line" ;;
	esac
	if [ "$gate" = premerge-gate ]; then
		count_pattern='^BLORP_GATE_RESULT gate=premerge-gate status=(PASS|FAIL) passed=([0-9]+) failed=([0-9]+) tests=([0-9]+)$'
		if [[ "$run_last_line" =~ $count_pattern ]]; then
			if (( 10#${BASH_REMATCH[2]} + 10#${BASH_REMATCH[3]} != 10#${BASH_REMATCH[4]} )); then
				fail "$name: final premerge counts do not sum to tests: $run_last_line"
			fi
		else
			fail "$name: final premerge verdict has malformed counts: $run_last_line"
		fi
	fi
	if [ "$zero" = yes ] && [ "$run_status" -ne 0 ]; then
		fail "$name: exit status should be 0, got $run_status"
	fi
	if [ "$zero" = no ] && [ "$run_status" -eq 0 ]; then
		fail "$name: exit status should be nonzero, got 0 with: $run_last_line"
	fi
	if [ "$failures" -ne "$failures_before" ]; then
		printf '%s\n' "$run_output" | sed 's/^/    | /'
	fi
}

expect_prompt_exit() {
	local name="$1"
	if [ "$run_signal_polls" -ge "$SIGNAL_EXIT_LIMIT_POLLS" ]; then
		fail "$name: took over $((SIGNAL_EXIT_LIMIT_POLLS * 5 / 100))s to exit after the signal"
	fi
}

# A gate that was stopped must not outlive the script that was asked to stop
# it, and must not print anything (a late nested verdict) after its verdict.
AFTER_VERDICT_WAIT_SECONDS=$((SLOW_GATE_SECONDS + 1))
expect_gate_stopped() {
	local fake_gate_pid
	fake_gate_pid=$(cat "$TMP_HARNESS/running-gate.pid")
	"$REAL_SLEEP" 0.2
	if [ -n "$fake_gate_pid" ] && kill -0 "$fake_gate_pid" 2>/dev/null; then
		fail "$1 left its running gate behind after the signal"
	fi
}
expect_quiet_after_verdict() {
	local name="$1" late_output
	"$REAL_SLEEP" "$AFTER_VERDICT_WAIT_SECONDS"
	late_output=$(cat "$TMP_HARNESS/$2.out")
	if [ "$late_output" != "$run_output" ]; then
		fail "$name: output arrived after the verdict line:"
		printf '%s\n' "$late_output" | tail -3 | sed 's/^/    | /'
	fi
	expect_gate_stopped "$name"
}

expect_no_verdict() {
	local name="$1"
	if grep -q '^BLORP_GATE_RESULT ' <<<"$run_output"; then
		fail "$name: should print no verdict line, got: $run_last_line"
	fi
}

# Every gate in these tests shares one slot directory, as checkouts do, and
# polls it quickly.
export BLORP_DOCKER_GATE_SLOT_DIR="$TMP_HARNESS/slots"
export BLORP_DOCKER_GATE_SLOT_POLL_SECONDS=0.1

# The most gate containers that were running at once, from docker-run.events.
max_concurrent_runs() {
	awk '$1 == "start" { running += 1; if (running > most) most = running }
	     $1 == "end" { running -= 1 }
	     END { print most + 0 }' "$TMP_HARNESS/docker-run.events"
}

# The labels of the runs, in the order they started.
run_start_order() {
	awk '$1 == "start" { printf "%s ", $2 }' "$TMP_HARNESS/docker-run.events" | sed 's/ $//'
}

# Slot and queue entries left in the shared directory.
leftover_slot_entries() {
	{ ls "$BLORP_DOCKER_GATE_SLOT_DIR" 2>/dev/null | grep -v '^queue$'
	  ls "$BLORP_DOCKER_GATE_SLOT_DIR/queue" 2>/dev/null; } | tr '\n' ' '
}

reset_slots() {
	rm -rf "$BLORP_DOCKER_GATE_SLOT_DIR" "$TMP_HARNESS/docker-run.events"
}

# An owner file for a gate that no longer exists: a pid no machine hands out.
write_dead_owner() {
	mkdir -p "$1"
	printf '4194303\nThu Jan  1 00:00:00 1970\n' > "$1/owner"
}

NESTED_PASS="BLORP_GATE_RESULT gate=premerge-gate status=PASS passed=7 failed=0 tests=7"
NESTED_FAIL="BLORP_GATE_RESULT gate=premerge-gate status=FAIL passed=6 failed=1 tests=7"
DOCKER_GATE=scripts/docker-gate

# --- scripts/docker-gate -----------------------------------------------------

# Waiting for a container slot (BLORP_DOCKER_GATE_MAX_CONCURRENT=0 never frees
# one) is a foreground sleep.
export BLORP_DOCKER_GATE_MAX_CONCURRENT=0
run_gate docker_slot_term TERM "Waiting:" "$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate TERM in slot wait" docker-gate FAIL no
expect_prompt_exit "docker-gate TERM in slot wait"

run_gate docker_slot_hup HUP "Waiting:" "$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate HUP in slot wait" docker-gate FAIL no
expect_prompt_exit "docker-gate HUP in slot wait"

if [ "$HAVE_PERL" = yes ]; then
	run_gate docker_slot_int INT "Waiting:" "$DOCKER_GATE" --premerge-gate
	expect_verdict "docker-gate INT in slot wait" docker-gate FAIL no
	expect_prompt_exit "docker-gate INT in slot wait"
fi
unset BLORP_DOCKER_GATE_MAX_CONCURRENT

FAKE_DOCKER_RUN=hang run_gate docker_run_term TERM "container started" \
	"$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate TERM in docker run" docker-gate FAIL no
expect_prompt_exit "docker-gate TERM in docker run"
expect_gate_stopped "docker-gate TERM in docker run"

if [ "$HAVE_PERL" = yes ]; then
	FAKE_DOCKER_RUN=hang run_gate docker_run_int INT "container started" \
		"$DOCKER_GATE" --premerge-gate
	expect_verdict "docker-gate INT in docker run" docker-gate FAIL no
	expect_prompt_exit "docker-gate INT in docker run"
fi

# The `docker run | tee` an interrupted docker-gate leaves behind would print
# its nested PASS after the FAIL verdict, and keep the container running.
FAKE_DOCKER_RUN=slow FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate docker_orphan TERM \
	"container started" "$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate TERM before the nested verdict" docker-gate FAIL no
expect_prompt_exit "docker-gate TERM before the nested verdict"
expect_quiet_after_verdict "docker-gate TERM before the nested verdict" docker_orphan

FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate docker_pass none "" \
	"$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate nested PASS" docker-gate PASS yes
# Without --init the container's PID 1 ignores the TERM the docker client
# forwards, and the gate keeps running after the script is stopped.
case " $(cat "$TMP_HARNESS/docker-run.args") " in
	*" --init "*) ;;
	*) fail "docker-gate should start the gate container with --init" ;;
esac
case "$run_last_line" in
	*"passed=7 failed=0 tests=7") ;;
	*) fail "docker-gate nested PASS: counts should carry through, got: $run_last_line" ;;
esac

FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate docker_repeat_platform none "" \
	"$DOCKER_GATE" --premerge-gate --platform linux/amd64 --platform linux/amd64
expect_verdict "docker-gate repeated --platform" docker-gate PASS yes

FAKE_DOCKER_VERDICT="$NESTED_FAIL" run_gate docker_nested_fail none "" \
	"$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate nested FAIL with docker run exiting 0" docker-gate FAIL no

run_gate docker_no_verdict none "" "$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate container printed no verdict" docker-gate FAIL no

run_gate docker_dry_run none "" "$DOCKER_GATE" --dry-run --premerge-gate
expect_verdict "docker-gate dry run" docker-gate PASS yes

run_gate docker_help none "" "$DOCKER_GATE" --help
expect_no_verdict "docker-gate --help"

# --- docker-gate slots -------------------------------------------------------

# Three gates started together with one slot: one runs at a time.
reset_slots
export BLORP_DOCKER_GATE_MAX_CONCURRENT=1
export FAKE_DOCKER_RUN=slow FAKE_DOCKER_SLOW_SECONDS=2 FAKE_DOCKER_VERDICT="$NESTED_PASS"
start_gate slot_race_a none "$DOCKER_GATE" --premerge-gate
start_gate slot_race_b none "$DOCKER_GATE" --premerge-gate
start_gate slot_race_c none "$DOCKER_GATE" --premerge-gate
for racer in slot_race_a slot_race_b slot_race_c; do
	wait_for_exit "$racer"
	[ "$wait_status" -eq 0 ] || fail "$racer should pass, got exit $wait_status"
done
waiters=$(grep -l "^Waiting:" "$TMP_HARNESS"/slot_race_?.out | wc -l | tr -d ' ')
[ "$waiters" -eq 2 ] || fail "three gates racing for one slot: expected 2 to wait, $waiters did"
overlap=$(max_concurrent_runs)
[ "$overlap" -eq 1 ] || fail "three gates racing for one slot: $overlap containers ran at once"
left=$(leftover_slot_entries)
[ -z "$left" ] || fail "slot entries left after the gates finished: $left"
unset FAKE_DOCKER_RUN FAKE_DOCKER_SLOW_SECONDS FAKE_DOCKER_VERDICT

# Waiters are served in arrival order, and a TERM to the holder frees its slot.
reset_slots
FAKE_DOCKER_RUN=hang start_gate slot_order_a none "$DOCKER_GATE" --premerge-gate
wait_for_text slot_order_a "container started"
slot_order_a_pid="$START_PID"
export FAKE_DOCKER_RUN=slow FAKE_DOCKER_SLOW_SECONDS=1 FAKE_DOCKER_VERDICT="$NESTED_PASS"
start_gate slot_order_b none "$DOCKER_GATE" --premerge-gate
wait_for_text slot_order_b "^Waiting:"
start_gate slot_order_c none "$DOCKER_GATE" --premerge-gate
wait_for_text slot_order_c "^Waiting:"
start_gate slot_order_d none "$DOCKER_GATE" --premerge-gate
wait_for_text slot_order_d "^Waiting:"
if grep -q "start slot_order_[bcd]" "$TMP_HARNESS/docker-run.events"; then
	fail "a waiter started while the holder still held the only slot"
fi
kill -TERM "$slot_order_a_pid"
wait_for_exit slot_order_a
[ "$wait_status" -ne 0 ] || fail "the interrupted holder should exit nonzero"
for waiter in slot_order_b slot_order_c slot_order_d; do
	wait_for_exit "$waiter"
	[ "$wait_status" -eq 0 ] || fail "$waiter should pass once served, got exit $wait_status"
done
order=$(run_start_order)
[ "$order" = "slot_order_a slot_order_b slot_order_c slot_order_d" ] ||
	fail "waiters should be served in arrival order, got: $order"
left=$(leftover_slot_entries)
[ -z "$left" ] || fail "slot entries left after the interrupted holder and its waiters: $left"
unset FAKE_DOCKER_RUN FAKE_DOCKER_SLOW_SECONDS FAKE_DOCKER_VERDICT

# A slot and a queue ticket held by dead gates are reclaimed, whether their
# owner file names a dead pid or was never written (the claimant died between
# `mkdir` and writing it).
for dead_case in dead_pid ownerless; do
	reset_slots
	if [ "$dead_case" = dead_pid ]; then
		write_dead_owner "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1"
		write_dead_owner "$BLORP_DOCKER_GATE_SLOT_DIR/queue/ticket-00000001"
	else
		mkdir -p "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1" "$BLORP_DOCKER_GATE_SLOT_DIR/queue/ticket-00000001"
		touch -t 200001010000 "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1" \
			"$BLORP_DOCKER_GATE_SLOT_DIR/queue/ticket-00000001"
	fi
	FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate "slot_reclaim_$dead_case" none "" \
		"$DOCKER_GATE" --premerge-gate
	expect_verdict "docker-gate reclaiming a slot of a dead gate ($dead_case)" docker-gate PASS yes
	if grep -q "^Waiting:" <<<"$run_output"; then
		fail "a slot held by a dead gate ($dead_case) should be reclaimed without waiting"
	fi
done
unset BLORP_DOCKER_GATE_MAX_CONCURRENT

# A pid that is alive but whose start time differs is a reused pid, so its slot
# is reclaimed; one whose start time matches is a running gate and is respected,
# whatever time zone or locale the waiting gate runs in (ps prints the start
# time in the caller's zone, which would otherwise make a live holder look dead).
export BLORP_DOCKER_GATE_MAX_CONCURRENT=1
reset_slots
mkdir -p "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1"
printf '%s\nThu Jan  1 00:00:00 1970\n' "$$" > "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1/owner"
FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate slot_reused_pid none "" "$DOCKER_GATE" --premerge-gate
expect_verdict "docker-gate reclaiming a slot whose pid was reused" docker-gate PASS yes
if grep -q "^Waiting:" <<<"$run_output"; then
	fail "a slot whose pid was reused (live pid, other start time) should be reclaimed"
fi

reset_slots
"$REAL_SLEEP" 120 &
live_holder=$!
echo "$live_holder" >> "$FAKE_PIDS"
mkdir -p "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1"
printf '%s\n%s\n' "$live_holder" \
	"$(LC_ALL=C TZ=UTC ps -o lstart= -p "$live_holder" | sed 's/^ *//; s/ *$//')" \
	> "$BLORP_DOCKER_GATE_SLOT_DIR/slot-1/owner"
FAKE_DOCKER_VERDICT="$NESTED_PASS" TZ=Pacific/Auckland LC_ALL=C start_gate slot_live_holder none \
	"$DOCKER_GATE" --premerge-gate
wait_for_text slot_live_holder "^Waiting:"
"$REAL_SLEEP" 1
if grep -q "start slot_live_holder" "$TMP_HARNESS/docker-run.events" 2>/dev/null; then
	fail "a live holder's slot was taken over by a gate in another time zone"
fi
kill "$live_holder"
wait "$live_holder" 2>/dev/null
wait_for_exit slot_live_holder
[ "$wait_status" -eq 0 ] || fail "the waiting gate should run once the live holder is gone, got exit $wait_status"

unset BLORP_DOCKER_GATE_MAX_CONCURRENT

# Clean mode builds an image (the memory-heavy `make`) and then runs it, all
# under one slot, which an interrupt must free.
reset_slots
FAKE_DOCKER_RUN=hang run_gate slot_clean_term TERM "container started" "$DOCKER_GATE" --clean
left=$(leftover_slot_entries)
[ -z "$left" ] || fail "an interrupted --clean run left slot entries: $left"
reset_slots

# An interrupted wait leaves no queue ticket behind.
reset_slots
export BLORP_DOCKER_GATE_MAX_CONCURRENT=0
run_gate slot_wait_cleanup TERM "^Waiting:" "$DOCKER_GATE" --premerge-gate
left=$(leftover_slot_entries)
[ -z "$left" ] || fail "an interrupted waiter left a queue entry: $left"
unset BLORP_DOCKER_GATE_MAX_CONCURRENT

# The build's parallelism is passed in: the VM's CPUs shared among the slots,
# at least 2, unless overridden.
check_build_jobs() {
	local expected="$1" label="$2"
	shift 2
	reset_slots
	FAKE_DOCKER_VERDICT="$NESTED_PASS" run_gate build_jobs none "" "$DOCKER_GATE" --premerge-gate "$@"
	case " $(cat "$TMP_HARNESS/docker-run.args") " in
		*" BLORP_CLI_C_SPLIT_JOBS=$expected "*) ;;
		*) fail "$label: expected BLORP_CLI_C_SPLIT_JOBS=$expected in: $(cat "$TMP_HARNESS/docker-run.args")" ;;
	esac
}
check_build_jobs 2 "8 CPUs, 3 slots (the default)"
BLORP_DOCKER_GATE_MAX_CONCURRENT=2 check_build_jobs 4 "8 CPUs, 2 slots"
FAKE_DOCKER_NCPU=3 check_build_jobs 2 "3 CPUs, 3 slots (the minimum)"
BLORP_DOCKER_GATE_MAX_CONCURRENT=1 check_build_jobs 8 "8 CPUs, 1 slot"
BLORP_DOCKER_GATE_BUILD_JOBS=3 check_build_jobs 3 "BLORP_DOCKER_GATE_BUILD_JOBS=3"
BLORP_DOCKER_GATE_BUILD_JOBS=zero run_gate build_jobs_bad none "" "$DOCKER_GATE" --premerge-gate
[ "$run_status" -ne 0 ] || fail "a non-numeric BLORP_DOCKER_GATE_BUILD_JOBS should be rejected"
reset_slots

# --- scripts/premerge-gate ---------------------------------------------------

# Skips every step that would need a real checkout; what remains is the
# preflight, build, the (fake) test gate, the codegen audit and drift checks.
PREMERGE_FLAGS=(--quick --no-quality --no-security --no-examples-check)
PREMERGE_GATE=scripts/premerge-gate
# premerge-gate runs `scripts/test`; swap in the fake for these cases.
cp "$SANDBOX/scripts/test" "$SANDBOX/scripts/test.real"
cp "$SANDBOX/scripts/test.fake" "$SANDBOX/scripts/test"

run_gate premerge_pass none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate normal run" premerge-gate PASS yes

FAKE_GATE_VERDICT=$'BLORP_GATE_RESULT gate=cli status=PASS passed=1 failed=0 tests=1\nBLORP_GATE_RESULT gate=test status=PASS passed=4 failed=0 tests=4' \
	run_gate premerge_sub_gate none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate reads test aggregate after sub-gate" premerge-gate PASS yes

FAKE_GATE_VERDICT="" run_gate premerge_missing_nested none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate missing nested verdict" premerge-gate FAIL no

FAKE_GATE_VERDICT="BLORP_GATE_RESULT gate=cli status=PASS passed=4 failed=0 tests=4" \
	run_gate premerge_wrong_nested none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate wrong nested verdict" premerge-gate FAIL no

FAKE_GATE_VERDICT="BLORP_GATE_RESULT gate=test status=PASS passed=oops failed=0 tests=4" \
	run_gate premerge_malformed_nested none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate malformed nested verdict" premerge-gate FAIL no

FAKE_GATE_VERDICT="BLORP_GATE_RESULT gate=test status=PASS passed=3 failed=0 tests=4" \
	run_gate premerge_wrong_counts none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate inconsistent nested counts" premerge-gate FAIL no

FAKE_GATE_VERDICT="BLORP_GATE_RESULT gate=test status=PASS passed=18446744073709551616 failed=0 tests=0" \
	run_gate premerge_overflow_counts none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate overflowing nested counts" premerge-gate FAIL no

FAKE_GATE_VERDICT=$'BLORP_GATE_RESULT gate=test status=PASS passed=4 failed=0 tests=4\nBLORP_GATE_RESULT gate=test status=PASS passed=4 failed=0 tests=4' \
	run_gate premerge_duplicate_nested none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate duplicate nested verdict" premerge-gate FAIL no

FAKE_GATE_VERDICT=$'BLORP_GATE_RESULT gate=test status=PASS passed=4 failed=0 tests=4\nBLORP_GATE_RESULT gate=cli status=PASS passed=1 failed=0 tests=1' \
	run_gate premerge_wrong_last_nested none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate wrong last nested verdict" premerge-gate FAIL no

FAKE_GATE_STATUS=FAIL run_gate premerge_nested_fail none "" "$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate nested FAIL" premerge-gate FAIL no

FAKE_GATE_RUN=hang run_gate premerge_term TERM "gate started" \
	"$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate TERM in scripts/test" premerge-gate FAIL no
expect_prompt_exit "premerge-gate TERM in scripts/test"
expect_gate_stopped "premerge-gate TERM in scripts/test"

FAKE_GATE_RUN=slow FAKE_GATE_STATUS=PASS run_gate premerge_orphan TERM "gate started" \
	"$PREMERGE_GATE" "${PREMERGE_FLAGS[@]}"
expect_verdict "premerge-gate TERM before scripts/test's verdict" premerge-gate FAIL no
expect_prompt_exit "premerge-gate TERM before scripts/test's verdict"
expect_quiet_after_verdict "premerge-gate TERM before scripts/test's verdict" premerge_orphan

# A help screen and a dry run validate nothing, so they must not claim PASS.
run_gate premerge_help none "" "$PREMERGE_GATE" --help
expect_no_verdict "premerge-gate --help"
[ "$run_status" -eq 0 ] || fail "premerge-gate --help should exit 0"
run_gate premerge_dry_run none "" "$PREMERGE_GATE" --dry-run
expect_no_verdict "premerge-gate --dry-run"
[ "$run_status" -eq 0 ] || fail "premerge-gate --dry-run should exit 0"

# --- scripts/test ------------------------------------------------------------

cp "$SANDBOX/scripts/test.real" "$SANDBOX/scripts/test"
TEST_GATE=scripts/test

run_gate test_help none "" "$TEST_GATE" --help
expect_no_verdict "scripts/test --help"
[ "$run_status" -eq 0 ] || fail "scripts/test --help should exit 0"
run_gate test_bad_flag none "" "$TEST_GATE" --no-such-flag
expect_verdict "scripts/test unknown argument" test FAIL no
run_gate test_log_dir_missing none "" "$TEST_GATE" --log-dir
expect_verdict "scripts/test --log-dir without a path" test FAIL no

run_gate test_pass none "" "$TEST_GATE" --no-build --serial cli
expect_verdict "scripts/test normal run" test PASS yes

# Serial mode runs the gate in the foreground.
FAKE_GATE_RUN=hang run_gate test_serial_term TERM "CLI Smoke" \
	"$TEST_GATE" --no-build --serial cli
expect_verdict "scripts/test TERM during a serial gate" test FAIL no
expect_prompt_exit "scripts/test TERM during a serial gate"

expect_gate_stopped "scripts/test (serial)"

# Parallel mode runs each gate in a background subshell.
FAKE_GATE_RUN=hang run_gate test_parallel_term TERM "RUN gate: cli" \
	"$TEST_GATE" --no-build cli package
expect_verdict "scripts/test TERM during a parallel wave" test FAIL no
expect_prompt_exit "scripts/test TERM during a parallel wave"
expect_gate_stopped "scripts/test (parallel)"

if [ "$HAVE_PERL" = yes ]; then
	FAKE_GATE_RUN=hang run_gate test_serial_int INT "CLI Smoke" \
		"$TEST_GATE" --no-build --serial cli
	expect_verdict "scripts/test INT during a serial gate" test FAIL no
	expect_prompt_exit "scripts/test INT during a serial gate"
fi

if [ "$failures" -ne 0 ]; then
	echo "$failures gate interrupt verdict check(s) failed"
	exit 1
fi
echo "Gate interrupt verdict checks passed"
