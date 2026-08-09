#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"
runner="${1:-$repo_root/compiler/_build/default/test/runner/compiler_fixture_runner.exe}"

if [ ! -x "$runner" ]; then
    echo "Compiler fixture runner not found: $runner" >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-runner-process.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

fake_blorp="$tmpdir/fake-blorp"
cat > "$fake_blorp" <<'SH'
#!/usr/bin/env bash
case "${BLORP_FAKE_MODE:-leader}" in
    capture-descendant)
        (
            trap '' TERM
            sleep 10
        ) &
        exit 0
        ;;
    inherited-group-descendant)
        sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 10' sh \
            "$BLORP_FAKE_PID_FILE" >/dev/null 2>&1 &
        while [ ! -s "$BLORP_FAKE_PID_FILE" ]; do
            sleep 0.01
        done
        exit 0
        ;;
    capture-group-descendant)
        sh -c 'trap "" TERM; echo $$ > "$1"; exec sleep 10' sh \
            "$BLORP_FAKE_PID_FILE" &
        while [ ! -s "$BLORP_FAKE_PID_FILE" ]; do
            sleep 0.01
        done
        exit 0
        ;;
    leader)
        trap '' TERM
        sleep 10
        ;;
    sustained-output)
        trap '' TERM
        while :; do
            printf '%4096s' ''
            sleep 0.01
        done
        ;;
    capture-limit)
        trap '' TERM
        exec yes flood
        ;;
esac
SH
chmod +x "$fake_blorp"

run_timeout_probe() {
    local name="$1"
    local mode="$2"
    local output_file="$tmpdir/$name.output"
    local started=$SECONDS
    local status elapsed

    set +e
    (
        cd "$repo_root"
        BLORP_FAKE_MODE="$mode" "$runner" \
            --blorp-bin "$fake_blorp" \
            --timeout 1 \
            -j 1 \
            --filter compile_time_lambda_callback.brp \
            --no-codegen-audit \
            --no-tool-fixtures
    ) > "$output_file" 2>&1
    status=$?
    set -e
    elapsed=$((SECONDS - started))

    if [ "$status" -ne 1 ]; then
        echo "Expected $name timeout to fail with status 1, got $status" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if [ "$elapsed" -gt 5 ]; then
        echo "Expected bounded $name timeout, elapsed ${elapsed}s" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if ! grep -Fq 'DETAIL Compilation timed out' "$output_file" ||
        ! grep -Fq \
            'BLORP_GATE_RESULT gate=compiler status=FAIL passed=0 failed=1 tests=1' \
            "$output_file"
    then
        echo "$name timeout did not report one timed-out case" >&2
        cat "$output_file" >&2
        exit 1
    fi
}

run_capture_limit_probe() {
    local name="$1"
    local timeout="$2"
    local output_file="$tmpdir/capture-limit-$name.output"
    local started=$SECONDS
    local status elapsed

    set +e
    (
        cd "$repo_root"
        BLORP_FAKE_MODE=capture-limit "$runner" \
            --blorp-bin "$fake_blorp" \
            --timeout "$timeout" \
            -j 1 \
            --filter compile_time_lambda_callback.brp \
            --no-codegen-audit \
            --no-tool-fixtures
    ) > "$output_file" 2>&1
    status=$?
    set -e
    elapsed=$((SECONDS - started))

    if [ "$status" -ne 1 ] || [ "$elapsed" -gt 5 ]; then
        echo "Expected bounded $name capture-limit failure" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if ! grep -Fq \
        'DETAIL Process output exceeded the 8388608-byte capture limit' \
        "$output_file" ||
        ! grep -Fq \
            'BLORP_GATE_RESULT gate=compiler status=FAIL passed=0 failed=1 tests=1' \
            "$output_file"
    then
        echo "$name capture-limit probe did not report one infrastructure failure" >&2
        cat "$output_file" >&2
        exit 1
    fi
}

run_inherited_group_probe() {
    local name="$1"
    local timeout="$2"
    local mode="$3"
    local output_file="$tmpdir/inherited-group-$name.output"
    local pid_file="$tmpdir/inherited-group-$name.pid"
    local started=$SECONDS
    local status elapsed pid

    set +e
    (
        cd "$repo_root"
        BLORP_FAKE_MODE="$mode" \
            BLORP_FAKE_PID_FILE="$pid_file" \
            "$runner" \
                --blorp-bin "$fake_blorp" \
                --timeout "$timeout" \
                -j 1 \
                --filter compile_time_lambda_callback.brp \
                --no-codegen-audit \
                --no-tool-fixtures
    ) > "$output_file" 2>&1
    status=$?
    set -e
    elapsed=$((SECONDS - started))

    if [ "$status" -ne 0 ] || [ "$elapsed" -gt 5 ]; then
        echo "Expected bounded $name inherited-group cleanup" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if [ ! -s "$pid_file" ]; then
        echo "$name inherited-group probe did not record its process" >&2
        cat "$output_file" >&2
        exit 1
    fi
    pid=$(cat "$pid_file")
    for _ in $(seq 1 20); do
        if ! kill -0 "$pid" 2>/dev/null; then
            pid=""
            break
        fi
        sleep 0.05
    done
    if [ -n "$pid" ]; then
        kill -KILL "$pid" 2>/dev/null || true
        echo "Fixture runner left inherited-group descendant $pid running" >&2
        cat "$output_file" >&2
        exit 1
    fi

    if ! grep -Fq \
        'BLORP_GATE_RESULT gate=compiler status=PASS passed=1 failed=0 tests=1' \
        "$output_file"
    then
        echo "Inherited-group cleanup changed the leader result" >&2
        cat "$output_file" >&2
        exit 1
    fi
}

run_timeout_probe leader leader
run_timeout_probe descendant capture-descendant
run_timeout_probe sustained-output sustained-output
run_capture_limit_probe timed 5
run_capture_limit_probe no-timeout 0
run_inherited_group_probe timed 1 inherited-group-descendant
run_inherited_group_probe no-timeout 0 capture-group-descendant

echo "PASS: compiler fixture process supervision is bounded"
