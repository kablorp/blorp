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
if ! grep -Fq 'compiler/_build/blorp-cli/compiler_runtime_sources.c' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must link the generated runtime source provider" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_COMPILER_RUNTIME_SOURCES=1' <<<"$cli_build_plan"; then
	echo "FAIL: the compiler-only runtime source hooks must be explicitly enabled" >&2
	exit 1
fi

install_plan=$(make -n install)
if ! grep -Fq 'cp "compiler/_build/default/bin/blorp_ocaml_middle.exe" "./blorp-ocaml-middle"' <<<"$install_plan"; then
	echo "FAIL: install must place the semantic worker beside the Blorp CLI" >&2
	exit 1
fi

setup_action=.github/actions/setup-cached-ocaml/action.yml
if grep -Eq '~/.cache/dune|~/Library/Caches/dune' "$setup_action"; then
	echo "FAIL: the opam dependency cache must not own Dune build artifacts" >&2
	exit 1
fi

for workflow in \
	.github/workflows/ci.yml \
	.github/workflows/premerge.yml \
	.github/workflows/benchmarks.yml \
	.github/workflows/release.yml
do
	if ! grep -Fq 'name: Cache Dune build artifacts' "$workflow"; then
		echo "FAIL: $workflow must cache Dune build artifacts explicitly" >&2
		exit 1
	fi
done

echo "PASS: build and CI cache ownership is explicit"
