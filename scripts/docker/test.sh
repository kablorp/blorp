#!/bin/bash
set -euo pipefail
eval $(opam env)

# If running from volume mount, copy to writable temp dir (excludes macOS _build artifacts)
if [ "${BLORP_VOLUME_MODE:-0}" = "1" ]; then
    mkdir -p /tmp/blorp-work
    tar -c --exclude='compiler/_build' --exclude='.git' --exclude='blorp' -C /blorp . | tar -x -C /tmp/blorp-work
    cd /tmp/blorp-work
fi

make
if [ $# -gt 0 ]; then
    ./blorp test "$@"
else
    bash scripts/run_tests.sh
fi
