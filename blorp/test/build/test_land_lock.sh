#!/bin/bash
# scripts/land serializes landings with one symlink lock in the shared git
# directory; the link target names the holder. Extract acquire_land_lock from
# the script and exercise it in a scratch repository: a second acquirer waits,
# a dead holder is taken over, and SIGTERM to a holder releases the lock.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/blorp-land-lock.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

git init -q "$scratch/repo"
cd "$scratch/repo"
sed -n '/^acquire_land_lock() {/,/^}/p' "$repo_root/scripts/land" > "$scratch/acquire.sh"
[ -s "$scratch/acquire.sh" ] || { echo "FAIL: acquire_land_lock not found in scripts/land"; exit 1; }
grep -Fq 'land_lock="$(git rev-parse --path-format=absolute --git-common-dir)/land.lock"' "$repo_root/scripts/land" ||
	{ echo "FAIL: scripts/land must keep its lock in the shared git directory"; exit 1; }

land_lock="$(git rev-parse --path-format=absolute --git-common-dir)/land.lock"
export LAND_LOCK_POLL_SECONDS=1

# Each holder is its own bash process, as scripts/land is, so pids, traps and
# signals behave as they do in a real landing. It holds the lock for $2 seconds.
cat > "$scratch/hold.sh" <<HOLD
set -euo pipefail
ref="\$1"
land_lock="$land_lock"
source "$scratch/acquire.sh"
acquire_land_lock
sleep "\$2" & wait \$!
HOLD
acquire_and_hold() { bash "$scratch/hold.sh" "$@"; }

# 1. A second acquirer waits for the first and then succeeds.
bash "$scratch/hold.sh" first 4 > "$scratch/first.log" &
first_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -L "$land_lock" ] && break; sleep 0.5; done
[ -L "$land_lock" ] || { echo "FAIL: first acquirer never took the lock"; exit 1; }
start=$(date +%s)
acquire_and_hold second 0 > "$scratch/second.log"
waited=$(( $(date +%s) - start ))
wait "$first_pid"
grep -Fq 'queued behind' "$scratch/second.log" || { echo "FAIL: second acquirer did not queue"; exit 1; }
[ "$waited" -ge 2 ] || { echo "FAIL: second acquirer did not wait (${waited}s)"; exit 1; }
[ ! -L "$land_lock" ] || { echo "FAIL: lock not released on exit"; exit 1; }

# 2. A lock whose holder pid is dead is taken over.
sleep 0 & dead_pid=$!
wait "$dead_pid"
ln -s "$dead_pid stale-ref 00:00" "$land_lock"
acquire_and_hold takeover 0 > "$scratch/takeover.log"
! grep -Fq 'queued behind' "$scratch/takeover.log" || { echo "FAIL: dead holder was not taken over"; exit 1; }
[ ! -L "$land_lock" ] || { echo "FAIL: lock not released after takeover"; exit 1; }

# 3. SIGTERM to a holder releases the lock.
bash "$scratch/hold.sh" terminated 30 > "$scratch/terminated.log" &
holder_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -L "$land_lock" ] && break; sleep 0.5; done
[ -L "$land_lock" ] || { echo "FAIL: holder never took the lock"; exit 1; }
kill -TERM "$holder_pid"
wait "$holder_pid" || true
[ ! -L "$land_lock" ] || { echo "FAIL: SIGTERM left the lock behind"; exit 1; }

echo "PASS: scripts/land lock queues, recovers from dead holders, and releases on SIGTERM"
