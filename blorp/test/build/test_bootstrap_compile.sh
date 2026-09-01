#!/usr/bin/env bash
# The bootstrap bridge must depend only on the portable tools it actually uses.

set -euo pipefail

cd "$(dirname "$0")/../../.."

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-bootstrap-compile-test.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

restricted_bin="$tmp_dir/bin"
mkdir -p "$restricted_bin"
for tool in cp dirname find mkdir mktemp perl; do
	tool_path=$(command -v "$tool")
	ln -s "$tool_path" "$restricted_bin/$tool"
done

bootstrap=$(scripts/blorp-compiler-bootstrap --print-path)
generated_c="$tmp_dir/generate_build_sources.c"

# Deliberately exclude rg. The GitHub runner does not guarantee that optional
# search utility, and the bridge's source rewrite must still be complete.
PATH="$restricted_bin" /bin/bash scripts/blorp-bootstrap-compile \
	tool "$bootstrap" "$generated_c" blorp/tool/generate_build_sources.brp

cc -O2 -fwrapv -pipe -w "$generated_c" -lm -lpthread \
	-o "$tmp_dir/generate-build-sources"

echo "PASS: bootstrap compilation works without rg"
