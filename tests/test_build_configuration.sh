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

bootstrap_manifest=compiler/bootstrap.env
if [ ! -f "$bootstrap_manifest" ]; then
	echo "FAIL: the compiler bootstrap must have one checked-in manifest" >&2
	exit 1
fi

# The manifest is checked-in shell data so the bootstrap wrapper and CI can
# share one release identity without maintaining a second parser.
# shellcheck source=../compiler/bootstrap.env
source "$bootstrap_manifest"

for required_bootstrap_value in \
	BLORP_BOOTSTRAP_REPO \
	BLORP_BOOTSTRAP_TAG \
	BLORP_BOOTSTRAP_VERSION \
	BLORP_BOOTSTRAP_LAYOUT \
	BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN \
	BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU \
	BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU
do
	if [ -z "${!required_bootstrap_value:-}" ]; then
		echo "FAIL: $bootstrap_manifest must define $required_bootstrap_value" >&2
		exit 1
	fi
done

case "$BLORP_BOOTSTRAP_LAYOUT" in
	single | toolchain) ;;
	*)
		echo "FAIL: $bootstrap_manifest must declare a supported archive layout" >&2
		exit 1
		;;
esac

if [[ ! "$BLORP_BOOTSTRAP_TAG" =~ ^dev-[0-9a-f]{12}$ ]]; then
	echo "FAIL: $bootstrap_manifest must pin an immutable dev revision" >&2
	exit 1
fi

bootstrap_revision=${BLORP_BOOTSTRAP_TAG#dev-}
if [[ "$BLORP_BOOTSTRAP_VERSION" != *"-dev.$bootstrap_revision" ]]; then
	echo "FAIL: the bootstrap artifact version must match $BLORP_BOOTSTRAP_TAG" >&2
	exit 1
fi

for bootstrap_sha in \
	"$BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN" \
	"$BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU" \
	"$BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU"
do
	if [[ ! "$bootstrap_sha" =~ ^[0-9a-f]{64}$ ]]; then
		echo "FAIL: $bootstrap_manifest contains an invalid target checksum" >&2
		exit 1
	fi
done

if [ "$(scripts/blorp-compiler-bootstrap --print-tag)" != "$BLORP_BOOTSTRAP_TAG" ]; then
	echo "FAIL: the bootstrap wrapper must read its default tag from $bootstrap_manifest" >&2
	exit 1
fi

overridden_tag=$(BLORP_COMPILER_BOOTSTRAP_TAG=dev-000000000000 \
	scripts/blorp-compiler-bootstrap --print-tag)
if [ "$overridden_tag" != "$BLORP_BOOTSTRAP_TAG" ]; then
	echo "FAIL: an ambient environment variable must not override the bootstrap manifest" >&2
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
	if grep -Eq 'BLORP_COMPILER_BOOTSTRAP_TAG: dev-[0-9a-f]+' "$workflow"; then
		echo "FAIL: $workflow must not carry an independent compiler bootstrap pin" >&2
		exit 1
	fi
	if ! grep -Fq 'id: compiler-bootstrap' "$workflow"; then
		echo "FAIL: $workflow must load the compiler bootstrap manifest" >&2
		exit 1
	fi
	if ! grep -Fq 'steps.compiler-bootstrap.outputs.tag' "$workflow"; then
		echo "FAIL: $workflow cache keys must use the compiler bootstrap manifest tag" >&2
		exit 1
	fi
	if ! grep -Fq 'key: blorp-compiler-bootstrap-v2-' "$workflow"; then
		echo "FAIL: $workflow must use the complete-toolchain bootstrap cache schema" >&2
		exit 1
	fi
done

ci_workflow=.github/workflows/ci.yml
if ! grep -Fq 'name: Check compiler self-hosting graph' "$ci_workflow" ||
	! grep -Fq 'compiler_parser_bridge_cli.brp' "$ci_workflow"
then
	echo "FAIL: normal CI must check the compiler source graph with the built compiler" >&2
	exit 1
fi

premerge_workflow=.github/workflows/premerge.yml
if ! grep -Fq 'BLORP_COMPILER_TEST_TIMEOUT: 180' "$premerge_workflow"; then
	echo "FAIL: premerge CI must preserve the measured compiler-suite timeout" >&2
	exit 1
fi

release_workflow=.github/workflows/release.yml
if ! grep -Fq 'name: Prepare packaged compiler bridges' "$release_workflow" ||
	! grep -Fq './blorp __compiler-bridge-prepare' "$release_workflow" ||
	! grep -Fq 'BLORP_RELEASE_PARSER_BRIDGE:' "$release_workflow" ||
	! grep -Fq 'name: Smoke packaged toolchain' "$release_workflow" ||
	! grep -Fq 'compiler_parser_bridge_cli.brp' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" compile' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" test' "$release_workflow"
then
	echo "FAIL: release CI must exercise self-hosting and both private workers from the archive" >&2
	exit 1
fi

echo "PASS: build and CI cache ownership is explicit"
