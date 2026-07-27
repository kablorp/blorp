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
if ! grep -Fq "find tools/formatter -name '*.brp' -type f -print" <<<"$cli_build_plan"; then
	echo "FAIL: formatter sources must participate in the Blorp CLI input identity" >&2
	exit 1
fi
if ! grep -Fq '"compiler/_build/default/bin/blorp_ocaml_host.exe" __compiler-bridge-prepare "compiler/_build/blorp-cli/prepared-bridges"' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must prepare current-source bridge helpers before compiling the compiler" >&2
	exit 1
fi
prepare_line=$(grep -Fn '__compiler-bridge-prepare' <<<"$cli_build_plan" | head -1 | cut -d: -f1)
compile_line=$(grep -Fn '__compiler-host-compile-wrapper' <<<"$cli_build_plan" | head -1 | cut -d: -f1)
if [ "$prepare_line" -ge "$compile_line" ]; then
	echo "FAIL: current-source bridge preparation must precede the full compiler host" >&2
	exit 1
fi
for prepared_bridge_binding in \
	'BLORP_COMPILER_RENDERER_BRIDGE_BIN="compiler/_build/blorp-cli/prepared-bridges/compiler_renderer_bridge.bin"' \
	'BLORP_COMPILER_PARSER_BRIDGE_BIN="compiler/_build/blorp-cli/prepared-bridges/compiler_parser_bridge.bin"' \
	'BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="compiler/_build/blorp-cli/prepared-bridges/compiler_typecheck_bridge.bin"'
do
	if ! grep -Fq "$prepared_bridge_binding" <<<"$cli_build_plan"; then
		echo "FAIL: the Blorp CLI build must pass every current-source prepared bridge to the compiler host" >&2
		exit 1
	fi
done
if ! grep -Fq 'BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE=1' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must require its current-source prepared bridge helpers" >&2
	exit 1
fi
if ! grep -Fq 'python3 -m unittest tests/test_runtime_allocator_stats.py' Makefile; then
	echo "FAIL: hygiene-check must include the optimized runtime allocator regression" >&2
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

if [ "$BLORP_BOOTSTRAP_LAYOUT" != "toolchain" ]; then
	echo "FAIL: $bootstrap_manifest must pin the complete compiler toolchain" >&2
	exit 1
fi

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

benchmark_cache=$(mktemp -d "${TMPDIR:-/tmp}/blorp-profile-cache-test.XXXXXX")
trap 'rm -rf "$benchmark_cache"' EXIT
mkdir -p "$benchmark_cache/compiler-typecheck-profile/fixed-hash"
profile_cache_binary="$benchmark_cache/compiler-typecheck-profile/fixed-hash/compiler_typecheck_profile"
printf '#!/usr/bin/env bash\nprintf "PROFILE_CACHE_SMOKE\\n"\n' >"$profile_cache_binary"
chmod +x "$profile_cache_binary"

make() {
	:
}

find() {
	:
}

shasum() {
	if [ "$#" -eq 2 ]; then
		while IFS= read -r _; do
			:
		done
	fi
	printf 'fixed-hash  mocked\n'
}

cc() {
	printf 'mock cc\n'
}

uname() {
	printf 'mock-platform\n'
}

export -f make find shasum cc uname
profile_cache_output=$(
	BLORP_BENCHMARK_CACHE_DIR="$benchmark_cache" \
	BLORP_COMPILER_BRIDGE_BIN=/bin/true \
	BLORP_BENCHMARK_USE_PREPARED_BRIDGES=0 \
	./benchmarks/compiler_typecheck_profile
)
unset -f make find shasum cc uname
if [ "$profile_cache_output" != "PROFILE_CACHE_SMOKE" ]; then
	echo "FAIL: compiler_typecheck_profile must support default mode under set -u" >&2
	exit 1
fi
rm -rf "$benchmark_cache"
trap - EXIT

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
