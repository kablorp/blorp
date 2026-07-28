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
if ! grep -Fq '[ ! -s "compiler/_build/blorp-cli/blorp_cli_main.c" ]' <<<"$cli_build_plan"; then
	echo "FAIL: a missing generated C artifact must invalidate the Blorp CLI build" >&2
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
if ! grep -Fq 'python3 -m unittest tests/test_runtime_allocator_stats.py' Makefile; then
	echo "FAIL: hygiene-check must include the optimized runtime allocator regression" >&2
	exit 1
fi
if ! grep -Fq -- '--print-toolchain-dir' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must resolve the pinned complete toolchain" >&2
	exit 1
fi
if ! grep -Fq -- '--print-compiler-path' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must resolve the immutable bootstrap compiler" >&2
	exit 1
fi
if grep -Fq '"compiler/_build/default/bin/blorp_ocaml_host.exe" __compiler-host-compile-wrapper' \
	<<<"$cli_build_plan"
then
	echo "FAIL: the Blorp CLI build must not compile itself through the current OCaml host" >&2
	exit 1
fi
if ! grep -Fq '"$bootstrap_compiler" __compiler-host-compile-wrapper' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must invoke the pinned bootstrap compiler" >&2
	exit 1
fi
if grep -R -Fq '__compiler-host-compile-wrapper' \
	compiler/bin compiler/blorp/src
then
	echo "FAIL: current compiler source must not retain the immutable bootstrap compiler command" >&2
	exit 1
fi
for compiler_benchmark in \
	benchmarks/compiler_record_layout \
	benchmarks/compiler_typecheck_profile
do
	if grep -Fq 'compiler/_build/default/bin/blorp_ocaml_host.exe' \
		"$compiler_benchmark"
	then
		echo "FAIL: $compiler_benchmark must not compile through the current OCaml host" >&2
		exit 1
	fi
	if grep -Fq '__compiler-host-compile-wrapper' "$compiler_benchmark"; then
		echo "FAIL: $compiler_benchmark must use the current public compiler surface" >&2
		exit 1
	fi
	if ! grep -Fq 'compile --' "$compiler_benchmark"; then
		echo "FAIL: $compiler_benchmark must compile its fixture with the current Blorp CLI" >&2
		exit 1
	fi
done
if ! grep -Fq \
	'compiler="${BLORP_TYPECHECK_PROFILE_COMPILER:-$repo_root/compiler/_build/blorp-cli/blorp}"' \
	benchmarks/compiler_typecheck_profile
then
	echo "FAIL: compiler_typecheck_profile must execute the artifact built by build-blorp-cli" >&2
	exit 1
fi
if ! grep -Fq \
	'compiler/_build/default/bin/blorp_ocaml_middle.exe' \
	benchmarks/compiler_typecheck_profile
then
	echo "FAIL: compiler_typecheck_profile must pair the build artifact with its semantic worker" >&2
	exit 1
fi
for bridge_env in \
	BLORP_COMPILER_RENDERER_BRIDGE_BIN \
	BLORP_COMPILER_PARSER_BRIDGE_BIN \
	BLORP_COMPILER_TYPECHECK_BRIDGE_BIN \
	BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE
do
	if ! grep -Fq "$bridge_env" <<<"$cli_build_plan"; then
		echo "FAIL: the Blorp CLI build must select and hash $bridge_env" >&2
		exit 1
	fi
done
if ! grep -Fq "sed -n '/^build-blorp-cli:/,/^# Run the top-level local test gate/p' Makefile" \
	<<<"$cli_build_plan"
then
	echo "FAIL: changes to the Blorp CLI build recipe must invalidate its output" >&2
	exit 1
fi
if grep -Fq "printf '%s\\n' Makefile " <<<"$cli_build_plan"; then
	echo "FAIL: install-only Makefile changes must not invalidate the Blorp CLI" >&2
	exit 1
fi
if ! grep -Fq \
	'new_hash=$(printf '\''%s\n%s\n%s\n'\'' "$source_hash" "$recipe_hash" "$require_prepared_bridge"' \
	<<<"$cli_build_plan"
then
	echo "FAIL: the prepared-bridge policy must participate in the Blorp CLI cache key" >&2
	exit 1
fi

if ! grep -Fq \
	'if [ "$helper_override_count" -ne 0 ] && [ "$helper_override_count" -ne 3 ]' \
	<<<"$cli_build_plan" ||
	! grep -Fq "bridge helper overrides must be provided together" <<<"$cli_build_plan"
then
	echo "FAIL: partial bridge helper overrides must produce a precise diagnostic" >&2
	exit 1
fi

if ! grep -Fxq 'hygiene-check: build-blorp-cli' Makefile; then
	echo "FAIL: hygiene checks must inspect generated C from the current CLI build" >&2
	exit 1
fi

stack_check=scripts/check-compiler-bridge-stack-usage
if ! grep -Fq 'compiler/_build/blorp-cli/blorp_cli_main.c' "$stack_check"; then
	echo "FAIL: the compiler bridge stack check must inspect the shipped CLI C" >&2
	exit 1
fi
if grep -Fq 'blorp-compiler-bootstrap' "$stack_check"; then
	echo "FAIL: the compiler bridge stack check must not regenerate isolated C with the bootstrap" >&2
	exit 1
fi

install_plan=$(make -n install)
if ! grep -Fq 'cp "compiler/_build/default/bin/blorp_ocaml_middle.exe" "./blorp-ocaml-middle"' <<<"$install_plan"; then
	echo "FAIL: install must place the semantic worker beside the Blorp CLI" >&2
	exit 1
fi
if ! grep -Fq 'bootstrap_toolchain_dir=$("scripts/blorp-compiler-bootstrap" --print-toolchain-dir)' <<<"$install_plan"; then
	echo "FAIL: install must resolve bridge helpers from the pinned complete toolchain" >&2
	exit 1
fi
if grep -Fq './blorp __compiler-bridge-prepare' <<<"$install_plan"; then
	echo "FAIL: ordinary install must not attempt an immediate second self-host" >&2
	exit 1
fi
for installed_bridge in \
	blorp-compiler-renderer \
	blorp-compiler-parser \
	blorp-compiler-typecheck
do
	if ! grep -Fq "$installed_bridge" <<<"$install_plan"; then
		echo "FAIL: install must place the pinned $installed_bridge beside the Blorp CLI" >&2
		exit 1
	fi
	if ! grep -Fxq "/$installed_bridge" .gitignore; then
		echo "FAIL: installed helper /$installed_bridge must be ignored as a build artifact" >&2
		exit 1
	fi
done
if ! grep -Fq 'scripts/install-compiler-bootstrap-helpers' <<<"$install_plan"
then
	echo "FAIL: install must verify and copy the pinned bridge helper generation" >&2
	exit 1
fi
if ! grep -Fq 'installed-bootstrap.id' <<<"$install_plan"; then
	echo "FAIL: install must record which bootstrap helper generation is installed" >&2
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
required_staged_toolchain='blorp blorp-ocaml-host blorp-ocaml-middle blorp-compiler-renderer blorp-compiler-parser blorp-compiler-typecheck'
ci_prepare_step=$(sed -n '/name: Prepare tested compiler bridges/,/name: Select compiler bridge toolchain/p' "$ci_workflow")
if ! grep -Fq 'name: Check compiler self-hosting graph' "$ci_workflow" ||
	! grep -Fq 'compiler_parser_bridge_cli.brp' "$ci_workflow"
then
	echo "FAIL: normal CI must check the compiler source graph with the built compiler" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_BUILD_VERSION: ${{ steps.release-meta.outputs.version }}' "$ci_workflow" ||
	! grep -Fq 'echo "BLORP_BUILD_VERSION=$version"' "$ci_workflow" ||
	! grep -Fq '>> "$GITHUB_ENV"' "$ci_workflow" ||
	! grep -Fq 'name: Prepare tested compiler bridges' "$ci_workflow" ||
	! grep -Fq 'current_toolchain="${RUNNER_TEMP}/blorp-current-toolchain"' "$ci_workflow" ||
	! grep -Fq 'BLORP_COMPILER_BRIDGE_BIN="$current_toolchain/blorp"' "$ci_workflow" ||
	! grep -Fq './blorp __compiler-bridge-prepare' "$ci_workflow" ||
	! grep -Fq 'name: Select compiler bridge toolchain' "$ci_workflow" ||
	! grep -Fq 'BLORP_COMPILER_PARSER_BRIDGE_BIN: ${{ steps.tested-bridges.outputs.parser }}' "$ci_workflow" ||
	! grep -Fq "BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE: '1'" "$ci_workflow" ||
	! grep -Fq 'name: Package tested toolchain' "$ci_workflow" ||
	! grep -Fq 'BLORP_RELEASE_PARSER_BRIDGE:' "$ci_workflow" ||
	! grep -Fq 'name: Smoke tested toolchain archive' "$ci_workflow" ||
	! grep -Fq 'test -x "$package_dir/blorp-bootstrap-compiler"' "$ci_workflow" ||
	! grep -Fq '"$package_dir/blorp-bootstrap-compiler" \' "$ci_workflow" ||
	! grep -Fq '__compiler-host-compile-wrapper \' "$ci_workflow" ||
	! grep -Fq 'test -s "$package_root/bootstrap-empty-main.c"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "blorp ${BLORP_RELEASE_VERSION}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "commit: ${BLORP_RELEASE_COMMIT}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "target: ${BLORP_RELEASE_TARGET}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "channel: ${BLORP_RELEASE_CHANNEL}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "dirty: false"' "$ci_workflow" ||
	! grep -Fq 'name: Upload tested toolchain archive' "$ci_workflow" ||
	! grep -Fq 'name: blorp-${{ steps.release-meta.outputs.target }}' "$ci_workflow" ||
	! grep -Fq 'path: dist/*' "$ci_workflow" ||
	! grep -Fq 'bash scripts/test --no-build --serial' "$ci_workflow"
then
	echo "FAIL: main CI must preserve and qualify the exact compiler it tested for dev releases" >&2
	exit 1
fi
for executable in $required_staged_toolchain; do
	if ! grep -Fq "            $executable" <<<"$ci_prepare_step"; then
		echo "FAIL: main CI must stage $executable before preparing compiler bridges" >&2
		exit 1
	fi
done
ci_prepare_line=$(grep -nF 'name: Prepare tested compiler bridges' "$ci_workflow" | head -n 1 | cut -d: -f1)
ci_test_line=$(grep -nF 'name: Run test suites' "$ci_workflow" | head -n 1 | cut -d: -f1)
if [ "$ci_prepare_line" -ge "$ci_test_line" ]; then
	echo "FAIL: main CI must prepare the packaged bridge generation before running tests" >&2
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

export -f find shasum cc uname
profile_cache_output=$(
	BLORP_BENCHMARK_CACHE_DIR="$benchmark_cache" \
	BLORP_COMPILER_BRIDGE_BIN=/usr/bin/true \
	BLORP_OCAML_MIDDLE_BIN=/usr/bin/true \
	BLORP_TYPECHECK_PROFILE_COMPILER=/usr/bin/true \
	BLORP_TYPECHECK_PROFILE_SKIP_BUILD=1 \
	BLORP_BENCHMARK_USE_PREPARED_BRIDGES=0 \
	./benchmarks/compiler_typecheck_profile
)
unset -f find shasum cc uname
if [ "$profile_cache_output" != "PROFILE_CACHE_SMOKE" ]; then
	echo "FAIL: compiler_typecheck_profile must support default mode under set -u" >&2
	exit 1
fi
rm -rf "$benchmark_cache"
trap - EXIT

release_workflow=.github/workflows/release.yml
release_build_job=$(sed -n '/^  build:/,/^  publish:/p' "$release_workflow")
release_publish_job=$(sed -n '/^  publish:/,$p' "$release_workflow")
release_prepare_step=$(sed -n '/name: Prepare packaged compiler bridges/,/name: Package binary/p' "$release_workflow")
if grep -Fq 'workflow_run' <<<"$release_build_job" ||
	! grep -Fq "github.event_name == 'push'" <<<"$release_build_job" ||
	! grep -Fq "startsWith(github.ref, 'refs/tags/v')" <<<"$release_build_job"
then
	echo "FAIL: successful main CI must not rebuild the tested compiler during release" >&2
	exit 1
fi
if grep -Fq 'make install' <<<"$release_publish_job"; then
	echo "FAIL: release publishing must not rebuild downloaded CI toolchains" >&2
	exit 1
fi
if ! grep -Fq 'name: Prepare packaged compiler bridges' "$release_workflow" ||
	! grep -Fq 'current_toolchain="${RUNNER_TEMP}/blorp-current-toolchain"' "$release_workflow" ||
	! grep -Fq 'BLORP_COMPILER_BRIDGE_BIN="$current_toolchain/blorp"' "$release_workflow" ||
	! grep -Fq './blorp __compiler-bridge-prepare' "$release_workflow" ||
	! grep -Fq 'BLORP_RELEASE_PARSER_BRIDGE:' "$release_workflow" ||
	! grep -Fq 'name: Smoke packaged toolchain' "$release_workflow" ||
	! grep -Fq 'test -x "$package_dir/blorp-bootstrap-compiler"' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp-bootstrap-compiler" \' "$release_workflow" ||
	! grep -Fq '__compiler-host-compile-wrapper \' "$release_workflow" ||
	! grep -Fq 'test -s "$package_root/bootstrap-empty-main.c"' "$release_workflow" ||
	! grep -Fq 'compiler_parser_bridge_cli.brp' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" compile' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" test' "$release_workflow" ||
	! grep -Fq 'name: Download tested CI binaries' "$release_workflow" ||
	! grep -Fq 'run-id: ${{ github.event.workflow_run.id }}' "$release_workflow" ||
	! grep -Fq 'pattern: blorp-*' "$release_workflow" ||
	! grep -Fq 'merge-multiple: true' "$release_workflow" ||
	! grep -Fq 'name: Validate release assets' "$release_workflow" ||
	! grep -Fq 'assets=(dist/*)' <<<"$release_publish_job" ||
	! grep -Fq 'actual=$(shasum -a 256 "$archive"' <<<"$release_publish_job" ||
	! grep -Fq '[ "$actual" != "$expected" ]' <<<"$release_publish_job" ||
	! grep -Fq 'x86_64-unknown-linux-gnu' <<<"$release_publish_job" ||
	! grep -Fq 'aarch64-unknown-linux-gnu' <<<"$release_publish_job" ||
	! grep -Fq 'aarch64-apple-darwin' <<<"$release_publish_job"
then
	echo "FAIL: release CI must consume tested dev archives and qualify independently versioned tag archives" >&2
	exit 1
fi
for executable in $required_staged_toolchain; do
	if ! grep -Fq "            $executable" <<<"$release_prepare_step"; then
		echo "FAIL: release CI must stage $executable before preparing compiler bridges" >&2
		exit 1
	fi
done

echo "PASS: build and CI cache ownership is explicit"
