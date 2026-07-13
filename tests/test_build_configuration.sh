#!/usr/bin/env bash
# Regression tests for the top-level build graph and CI cache ownership.

set -euo pipefail

cd "$(dirname "$0")/.."

build_plan=$(make -n build)
expected_ocaml_build='cd compiler && dune build bin/blorp_ocaml_host.exe bin/blorp_ocaml_middle.exe'
if ! grep -Fxq "$expected_ocaml_build" <<<"$build_plan"; then
	echo "FAIL: make build must target only the private OCaml host executables" >&2
	printf '%s\n' "$build_plan" >&2
	exit 1
fi

all_plan=$(make -n all)
if grep -Fq './blorp format --check' <<<"$all_plan"; then
	echo "FAIL: ordinary make must not execute formatter warm-up" >&2
	exit 1
fi

cli_build_plan=$(make -n build-blorp-cli)
if ! grep -Fq 'set -e;' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must stop after a failed compiler command" >&2
	exit 1
fi
if ! grep -Fq 'rm -f "compiler/_build/blorp-cli/blorp_cli_main.c"' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must remove stale generated C before compilation" >&2
	exit 1
fi
if ! grep -Fq 'tmp_bin="compiler/_build/blorp-cli/blorp.tmp"' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must publish the executable atomically" >&2
	exit 1
fi

cli_hash_block=$(sed -n '/new_hash=\$\$( {/,/old_hash=\$\$(cat/p' Makefile)
if [ -z "$cli_hash_block" ] || ! grep -Fq '"$$bridge_compiler"' <<<"$cli_hash_block"; then
	echo "FAIL: generated CLI artifacts must hash the concrete compiler executable" >&2
	exit 1
fi
if grep -Fq '"$(BLORP_COMPILER_BOOTSTRAP)"' <<<"$cli_hash_block"; then
	echo "FAIL: resolver-only edits must not invalidate generated CLI artifacts" >&2
	exit 1
fi

setup_action=.github/actions/setup-cached-ocaml/action.yml
if grep -Eq '~/.cache/dune|~/Library/Caches/dune' "$setup_action"; then
	echo "FAIL: the opam dependency cache must not own Dune build artifacts" >&2
	exit 1
fi

bootstrap=scripts/blorp-compiler-bootstrap
bootstrap_pin=scripts/blorp-compiler-bootstrap-pin.sh
if [ ! -f "$bootstrap_pin" ]; then
	echo "FAIL: the compiler bootstrap must have one checked-in pin manifest" >&2
	exit 1
fi

# shellcheck source=../scripts/blorp-compiler-bootstrap-pin.sh
source "$bootstrap_pin"
if [[ ! "$BLORP_BOOTSTRAP_RELEASE_REVISION" =~ ^[0-9a-f]{12}$ ]]; then
	echo "FAIL: the bootstrap release revision must be a 12-character lowercase commit prefix" >&2
	exit 1
fi
if [[ ! "$BLORP_BOOTSTRAP_RELEASE_BASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "FAIL: the bootstrap base version must use major.minor.patch syntax" >&2
	exit 1
fi
expected_bootstrap_id="dev-${BLORP_BOOTSTRAP_RELEASE_REVISION} ${BLORP_BOOTSTRAP_RELEASE_BASE_VERSION}-dev.${BLORP_BOOTSTRAP_RELEASE_REVISION}"
if [ "$("$bootstrap" --print-id)" != "$expected_bootstrap_id" ]; then
	echo "FAIL: the bootstrap tag and version must derive from the pin manifest revision" >&2
	exit 1
fi

for checksum in \
	"$BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN" \
	"$BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU" \
	"$BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU"
do
	if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
		echo "FAIL: compiler bootstrap checksums must be lowercase SHA-256 values" >&2
		exit 1
	fi
done

if override_output=$(BLORP_COMPILER_BOOTSTRAP_TAG=dev-invalid "$bootstrap" --print-id 2>&1); then
	echo "FAIL: the bootstrap must reject tag-only environment overrides" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_COMPILER_BOOTSTRAP_TAG is no longer supported' <<<"$override_output"; then
	echo "FAIL: the retired bootstrap tag override needs an actionable diagnostic" >&2
	printf '%s\n' "$override_output" >&2
	exit 1
fi

for workflow in .github/workflows/*.yml .github/workflows/*.yaml
do
	if [ ! -e "$workflow" ]; then
		continue
	fi
	if ! grep -Eq '(^|[[:space:]])make([[:space:]]|$)|scripts/(premerge-gate|test)|benchmarks/bench\.sh' "$workflow"; then
		continue
	fi
	if grep -Fq 'BLORP_COMPILER_BOOTSTRAP_TAG' "$workflow"; then
		echo "FAIL: $workflow must not override the bootstrap script's pinned release" >&2
		exit 1
	fi
	if ! grep -Fq "key: blorp-compiler-bootstrap-\${{ runner.os }}-\${{ runner.arch }}-\${{ hashFiles('scripts/blorp-compiler-bootstrap-pin.sh') }}-\${{ hashFiles('scripts/blorp-compiler-bootstrap') }}" "$workflow"; then
		echo "FAIL: $workflow must derive the bootstrap cache key from the pin and resolver" >&2
		exit 1
	fi
	if ! grep -Fq "blorp-compiler-bridge-v1-\${{ runner.os }}-\${{ runner.arch }}-\${{ hashFiles('scripts/blorp-compiler-bootstrap-pin.sh') }}-" "$workflow"; then
		echo "FAIL: $workflow must isolate bridge caches by bootstrap pin" >&2
		exit 1
	fi
	if ! grep -Fq "blorp-cli-v1-\${{ runner.os }}-\${{ runner.arch }}-\${{ hashFiles('scripts/blorp-compiler-bootstrap-pin.sh') }}-" "$workflow"; then
		echo "FAIL: $workflow must isolate generated CLI caches by bootstrap pin" >&2
		exit 1
	fi
	expensive_cache_lines=$(grep -E 'blorp-(compiler-bridge|cli)-v1-' "$workflow")
	if grep -Fq "hashFiles('scripts/blorp-compiler-bootstrap')" <<<"$expensive_cache_lines"; then
		echo "FAIL: $workflow must not invalidate compiled artifacts for resolver-only edits" >&2
		exit 1
	fi
	if ! grep -Fq 'name: Cache Dune build artifacts' "$workflow"; then
		echo "FAIL: $workflow must cache Dune build artifacts explicitly" >&2
		exit 1
	fi
done

echo "PASS: build and CI cache ownership is explicit"
