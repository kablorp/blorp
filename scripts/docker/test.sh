#!/bin/bash
set -euo pipefail
eval $(opam env)

FULL_GATE="${BLORP_DOCKER_FULL_GATE:-0}"

# If running from volume mount, copy to writable temp dir (excludes macOS _build artifacts)
if [ "${BLORP_VOLUME_MODE:-0}" = "1" ]; then
    mkdir -p /tmp/blorp-work
    tar_args=(--exclude='compiler/_build' --exclude='_build' --exclude='./blorp')
    if [ "$FULL_GATE" != "1" ]; then
        tar_args+=(--exclude='.git')
    fi
    tar -c "${tar_args[@]}" -C /blorp . | tar -x -C /tmp/blorp-work
    cd /tmp/blorp-work
fi

if [ "$FULL_GATE" = "1" ]; then
    bash scripts/full-gate --no-docker "$@"
elif [ $# -gt 0 ]; then
    make
    ./blorp test "$@"
else
    make
    bash scripts/run_tests.sh
fi
