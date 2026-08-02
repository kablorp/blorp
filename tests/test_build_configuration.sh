#!/usr/bin/env bash
# Regression tests for the top-level build graph and CI cache ownership.

set -euo pipefail

cd "$(dirname "$0")/.."

build_plan=$(make -n build)
expected_ocaml_build='cd compiler && dune build bin/blorp_ocaml_host.exe'
if ! grep -Fxq "$expected_ocaml_build" <<<"$build_plan"; then
	echo "FAIL: make build must target only the private OCaml host executables" >&2
	printf '%s\n' "$build_plan" >&2
	exit 1
fi
if grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$build_plan"; then
	echo "FAIL: make build must not compile the public Blorp CLI" >&2
	exit 1
fi

all_plan=$(make -n all)
if grep -Fq './blorp format --check' <<<"$all_plan"; then
	echo "FAIL: ordinary make must not execute formatter warm-up" >&2
	exit 1
fi

cli_build_plan=$(make -n build-blorp-cli)
if grep -Fxq "$expected_ocaml_build" <<<"$cli_build_plan"; then
	echo "FAIL: make build-blorp-cli must not build the private OCaml host" >&2
	exit 1
fi
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
if ! grep -Fq '$(BLORP_EMBEDDED_STD_SOURCE)' Makefile; then
	echo "FAIL: the generated embedded std source must remain a Blorp CLI prerequisite" >&2
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
if ! grep -Fq -- '--print-path' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must resolve the pinned public compiler" >&2
	exit 1
fi
if grep -Fq '"compiler/_build/default/bin/blorp_ocaml_host.exe" __compiler-host-compile-wrapper' \
	<<<"$cli_build_plan"
then
	echo "FAIL: the Blorp CLI build must not compile itself through the current OCaml host" >&2
	exit 1
fi
if ! grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must invoke the pinned public compile command" >&2
	exit 1
fi
if grep -R -Fq '__compiler-host-compile-wrapper' \
	compiler/bin compiler/blorp/src
then
	echo "FAIL: current compiler source must not retain the immutable bootstrap compiler command" >&2
	exit 1
fi
direct_compiler_benchmark=benchmarks/compiler_record_layout
if grep -Fq 'compiler/_build/default/bin/blorp_ocaml_host.exe' \
	"$direct_compiler_benchmark" ||
	grep -Fq '__compiler-host-compile-wrapper' "$direct_compiler_benchmark" ||
	! grep -Fq 'compile --' "$direct_compiler_benchmark"
then
	echo "FAIL: $direct_compiler_benchmark must compile through the current public CLI" >&2
	exit 1
fi

compiler_benchmark_runner=benchmarks/compiler_blorp_benchmark_runner
for compiler_benchmark in \
	benchmarks/compiler_import_graph_profile \
	benchmarks/compiler_typecheck_profile
do
	if ! grep -Eq '^exec "[$]script_dir/compiler_blorp_benchmark_runner" \\$' \
		"$compiler_benchmark"
	then
		echo "FAIL: $compiler_benchmark must delegate compilation to the shared runner" >&2
		exit 1
	fi
	if grep -Eq \
		'compiler/_build/default/bin/blorp_ocaml_host[.]exe|__compiler-host-compile-wrapper|blorp_ocaml_middle' \
		"$compiler_benchmark"
	then
		echo "FAIL: $compiler_benchmark must not retain retired OCaml compiler paths" >&2
		exit 1
	fi
done
if grep -Fq 'compiler/_build/default/bin/blorp_ocaml_host.exe' \
	"$compiler_benchmark_runner" ||
	grep -Fq '__compiler-host-compile-wrapper' "$compiler_benchmark_runner" ||
	grep -Fq 'blorp_ocaml_middle' "$compiler_benchmark_runner"
then
	echo "FAIL: the shared compiler benchmark runner must not use retired OCaml compiler paths" >&2
	exit 1
fi
if ! grep -Eq \
	'^compiler=.*[$]repo_root/compiler/_build/blorp-cli/blorp' \
	"$compiler_benchmark_runner"
then
	echo "FAIL: the shared compiler benchmark runner must default to the current Blorp CLI" >&2
	exit 1
fi
if [ ! -f compiler/blorp/benchmarks/compiler_typecheck_worker.brp ] ||
	[ -e compiler/blorp/src/stage_12_cli/compiler_typecheck_bridge_cli.brp ]
then
	echo "FAIL: the standalone typecheck worker must be owned by compiler benchmarks" >&2
	exit 1
fi
for typecheck_runner in \
	benchmarks/compiler_typecheck_memory \
	benchmarks/compiler_typecheck_replay
do
	if ! grep -Fq 'from compiler_typecheck_worker import' "$typecheck_runner" ||
		grep -Fq '__compiler-bridge-prepare' "$typecheck_runner"
	then
		echo "FAIL: $typecheck_runner must prepare its benchmark worker without the production bridge command" >&2
		exit 1
	fi
done
if ! grep -Fq 'benchmarks/compiler_typecheck_memory \' \
	.github/workflows/benchmarks.yml
then
	echo "FAIL: benchmark CI must compile, link, and run the benchmark-only typecheck worker" >&2
	exit 1
fi
if grep -Fq 'blorp-compiler-renderer' .github/workflows/benchmarks.yml; then
	echo "FAIL: benchmark CI must not stage the retired renderer worker" >&2
	exit 1
fi
if ! grep -Fq 'name: Test benchmark-only typecheck worker' \
	.github/workflows/ci.yml ||
	! grep -Fq 'benchmarks/compiler_typecheck_memory \' \
	.github/workflows/ci.yml
then
	echo "FAIL: required CI must compile, link, and run the benchmark-only typecheck worker" >&2
	exit 1
fi
for obsolete_build_input in \
	BLORP_COMPILER_BRIDGE_BIN \
	BLORP_COMPILER_RENDERER_BRIDGE_BIN \
	BLORP_COMPILER_PARSER_BRIDGE_BIN \
	BLORP_COMPILER_TYPECHECK_BRIDGE_BIN \
	BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE \
	__compiler-host-compile-wrapper
do
	if grep -Fq "$obsolete_build_input" <<<"$cli_build_plan"; then
		echo "FAIL: the Blorp CLI build must not retain obsolete bootstrap input $obsolete_build_input" >&2
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
	'new_hash=$(printf '\''%s\n%s\n'\'' "$source_hash" "$recipe_hash"' \
	<<<"$cli_build_plan"
then
	echo "FAIL: source and recipe identity must determine the Blorp CLI cache key" >&2
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
if ! grep -Fxq "$expected_ocaml_build" <<<"$install_plan"; then
	echo "FAIL: install must retain the private OCaml command host" >&2
	exit 1
fi
if ! grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$install_plan"; then
	echo "FAIL: install must retain the public Blorp CLI build" >&2
	exit 1
fi
if ! grep -Fq 'cp "compiler/_build/default/bin/blorp_ocaml_host.exe" "./blorp-ocaml-host"' \
	<<<"$install_plan" ||
	! grep -Fq 'cp "compiler/_build/blorp-cli/blorp" ./blorp' <<<"$install_plan"
then
	echo "FAIL: install must publish both the private host and public CLI" >&2
	exit 1
fi
if grep -Fq 'blorp-ocaml-middle' <<<"$install_plan"; then
	echo "FAIL: install must not retain the retired semantic worker" >&2
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
for installed_bridge in blorp-compiler-parser; do
	if ! grep -Fq "$installed_bridge" scripts/install-compiler-bootstrap-helpers; then
		echo "FAIL: the worker installer must place pinned $installed_bridge beside the Blorp CLI" >&2
		exit 1
	fi
	if ! grep -Fxq "/$installed_bridge" .gitignore; then
		echo "FAIL: installed helper /$installed_bridge must be ignored as a build artifact" >&2
		exit 1
	fi
done
if grep -Eq 'cp .*blorp-compiler-typecheck|mv .*blorp-compiler-typecheck' \
	scripts/install-compiler-bootstrap-helpers
then
	echo "FAIL: the worker installer must not publish the benchmark-only typecheck worker" >&2
	exit 1
fi
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
if ! grep -Fq 'name: Cache Dune build artifacts' "$setup_action" ||
	! grep -Fq '~/.cache/dune' "$setup_action" ||
	! grep -Fq '~/Library/Caches/dune' "$setup_action" ||
	! grep -Fq 'key: dune-v1-${{ runner.os }}-${{ runner.arch }}-${{ inputs.ocaml-compiler }}-${{ github.sha }}' "$setup_action" ||
	! grep -Fq 'dune-v1-${{ runner.os }}-${{ runner.arch }}-${{ inputs.ocaml-compiler }}-' "$setup_action"
then
	echo "FAIL: cached OCaml setup must own the shared Dune artifact cache" >&2
	exit 1
fi
for workflow in .github/workflows/*.yml; do
	if grep -Fq 'name: Cache Dune build artifacts' "$workflow" ||
		grep -Fq '~/.cache/dune' "$workflow" ||
		grep -Fq '~/Library/Caches/dune' "$workflow"
	then
		echo "FAIL: $workflow must use the Dune cache owned by cached OCaml setup" >&2
		exit 1
	fi
done

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
	.github/workflows/release.yml
do
	if ! grep -Fq 'uses: ./.github/actions/setup-cached-ocaml' "$workflow"; then
		echo "FAIL: $workflow must prepare the shared OCaml and Dune caches" >&2
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
if ! grep -Fq 'uses: ./.github/actions/setup-cached-ocaml' \
	.github/workflows/benchmarks.yml
then
	echo "FAIL: benchmarks must retain OCaml setup for comparison benchmarks" >&2
	exit 1
fi

ci_workflow=.github/workflows/ci.yml
required_staged_toolchain='blorp blorp-ocaml-host blorp-compiler-parser'
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
	! grep -Fq 'grep -Fxq "blorp ${BLORP_RELEASE_VERSION}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "commit: ${BLORP_RELEASE_COMMIT}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "target: ${BLORP_RELEASE_TARGET}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "channel: ${BLORP_RELEASE_CHANNEL}"' "$ci_workflow" ||
	! grep -Fq 'grep -Fxq "dirty: false"' "$ci_workflow" ||
	! grep -Fq '"$package_dir/blorp" purify --dry-run' "$ci_workflow" ||
	! grep -Fq 'name: Upload tested toolchain archive' "$ci_workflow" ||
	! grep -Fq 'name: blorp-${{ steps.release-meta.outputs.target }}' "$ci_workflow" ||
	! grep -Fq 'path: dist/*' "$ci_workflow" ||
	! grep -Fq 'bash scripts/test --no-build --serial compiler-unit compiler runtime leak doctest cli' "$ci_workflow" ||
	! grep -Fq 'bash scripts/test --no-build --serial runtime leak cli' "$ci_workflow"
then
	echo "FAIL: main CI must preserve and qualify the exact compiler it tested for dev releases" >&2
	exit 1
fi
if grep -Fq 'blorp-bootstrap-compiler' "$ci_workflow" ||
	grep -Fq '__compiler-host-compile-wrapper' "$ci_workflow"
then
	echo "FAIL: main CI must not retain the retired bootstrap helper bundle" >&2
	exit 1
fi
for executable in $required_staged_toolchain; do
	if ! grep -Fq "            $executable" <<<"$ci_prepare_step"; then
		echo "FAIL: main CI must stage $executable before preparing compiler bridges" >&2
		exit 1
	fi
done
for production_path in \
	scripts/test \
	scripts/package-release \
	scripts/install-dev \
	.github/workflows/ci.yml \
	.github/workflows/release.yml \
	.github/workflows/benchmarks.yml
do
	if grep -Eq 'BLORP_(COMPILER|RELEASE)_TYPECHECK_BRIDGE|compiler_typecheck_bridge[.]bin' "$production_path"; then
		echo "FAIL: $production_path must not retain the benchmark-only typecheck worker" >&2
		exit 1
	fi
	if grep -Eq 'BLORP_(COMPILER|RELEASE)_RENDERER_BRIDGE|compiler_renderer_bridge[.]bin' "$production_path"; then
		echo "FAIL: $production_path must not retain the benchmark-only renderer worker" >&2
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
profile_cache_binary="$benchmark_cache/compiler-typecheck-profile/fixed-hash/compiler-typecheck-profile"
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

benchmark_contract_root=$(mktemp -d "${TMPDIR:-/tmp}/blorp-benchmark-contract.XXXXXX")
trap 'rm -rf "$benchmark_contract_root"' EXIT
benchmark_fake_bin="$benchmark_contract_root/bin"
mkdir -p "$benchmark_fake_bin"

cat >"$benchmark_fake_bin/compiler" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${BLORP_FAKE_COMPILER_ARGS:?}"
printf '%s\n' "$@" >"$BLORP_FAKE_COMPILER_ARGS"
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-o" ]; then
		shift
		output=${1:-}
	fi
	shift
done
if [ -z "$output" ]; then
	echo "fake compiler did not receive -o" >&2
	exit 1
fi
printf 'int main(void) { return 0; }\n' >"$output"
SH

cat >"$benchmark_fake_bin/cc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then
	printf 'fake cc 1.0\n'
	exit 0
fi
: "${BLORP_FAKE_CC_ARGS:?}"
printf '%s\n' "$@" >"$BLORP_FAKE_CC_ARGS"
output=
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-o" ]; then
		shift
		output=${1:-}
	fi
	shift
done
if [ -z "$output" ]; then
	echo "fake C compiler did not receive -o" >&2
	exit 1
fi
printf '#!/usr/bin/env bash\nprintf "BENCHMARK_CONTRACT_SMOKE\\n"\n' >"$output"
chmod +x "$output"
SH

cat >"$benchmark_fake_bin/shasum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 2 ]; then
	while IFS= read -r _; do
		:
	done
fi
printf 'fixed-hash  mocked\n'
SH
chmod +x \
	"$benchmark_fake_bin/compiler" \
	"$benchmark_fake_bin/cc" \
	"$benchmark_fake_bin/shasum"

assert_compiler_benchmark_contract() {
	contract_name=$1
	benchmark_entrypoint=$2
	expected_source=$3
	expected_profile=$4
	expected_cc_optimization=$5
	compiler_args="$benchmark_contract_root/$contract_name.compiler-args"
	cc_args="$benchmark_contract_root/$contract_name.cc-args"
	benchmark_output=$(
		PATH="$benchmark_fake_bin:$PATH" \
		BLORP_BENCHMARK_CACHE_DIR="$benchmark_contract_root/cache-$contract_name" \
		BLORP_BENCHMARK_USE_PREPARED_BRIDGES=0 \
		BLORP_COMPILER_BENCHMARK_COMPILER="$benchmark_fake_bin/compiler" \
		BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
		BLORP_COMPILER_BRIDGE_BIN=/usr/bin/true \
		BLORP_FAKE_CC_ARGS="$cc_args" \
		BLORP_FAKE_COMPILER_ARGS="$compiler_args" \
		"$benchmark_entrypoint"
	)
	if [ "$benchmark_output" != "BENCHMARK_CONTRACT_SMOKE" ] ||
		[ "$(sed -n '1p' "$compiler_args")" != "compile" ] ||
		! grep -Fxq -- '--no-format' "$compiler_args" ||
		! grep -Fxq "$expected_source" "$compiler_args" ||
		! grep -Fxq -- "$expected_cc_optimization" "$cc_args"
	then
		echo "FAIL: $benchmark_entrypoint must compile its expected fixture through the public CLI" >&2
		exit 1
	fi
	if [ "$expected_profile" = "profile" ]; then
		if ! grep -Fxq -- '--profile' "$compiler_args"; then
			echo "FAIL: $benchmark_entrypoint must enable compiler profiling" >&2
			exit 1
		fi
	elif grep -Fxq -- '--profile' "$compiler_args"; then
		echo "FAIL: $benchmark_entrypoint must not enable compiler profiling by default" >&2
		exit 1
	fi
}

assert_compiler_benchmark_contract \
	import-graph \
	./benchmarks/compiler_import_graph_profile \
	"$PWD/compiler/blorp/benchmarks/compiler_import_graph_profile.brp" \
	plain \
	-O2
assert_compiler_benchmark_contract \
	typecheck \
	./benchmarks/compiler_typecheck_profile \
	"$PWD/compiler/blorp/benchmarks/compiler_typecheck_profile.brp" \
	profile \
	-O0

rm -rf "$benchmark_contract_root"
trap - EXIT

release_workflow=.github/workflows/release.yml
ci_build_step=$(sed -n '/name: Build compiler/,/name: Prepare tested compiler bridges/p' .github/workflows/ci.yml)
release_build_job=$(sed -n '/^  build:/,/^  publish:/p' "$release_workflow")
release_publish_job=$(sed -n '/^  publish:/,$p' "$release_workflow")
release_compiler_build_step=$(sed -n '/name: Build compiler/,/name: Prepare packaged compiler bridges/p' "$release_workflow")
release_prepare_step=$(sed -n '/name: Prepare packaged compiler bridges/,/name: Package binary/p' "$release_workflow")
if grep -Fq 'workflow_run' <<<"$release_build_job" ||
	! grep -Fq "github.event_name == 'push'" <<<"$release_build_job" ||
	! grep -Fq "startsWith(github.ref, 'refs/tags/v')" <<<"$release_build_job"
then
	echo "FAIL: successful main CI must not rebuild the tested compiler during release" >&2
	exit 1
fi
if grep -Eq '(^|[[:space:]])make([[:space:]]+[^[:space:]]+)*[[:space:]]+install([[:space:]]|$)' \
	<<<"$release_publish_job"
then
	echo "FAIL: release publishing must not rebuild downloaded CI toolchains" >&2
	exit 1
fi
for compiler_build_step in "$ci_build_step" "$release_compiler_build_step"; do
	if ! grep -Fq 'if [ "$RUNNER_OS" = "Linux" ]; then' <<<"$compiler_build_step" ||
		! grep -Fq 'opam exec -- make -j2 install' <<<"$compiler_build_step" ||
		! grep -Fq 'opam exec -- make install' <<<"$compiler_build_step"
	then
		echo "FAIL: Linux compiler builds must use two Make jobs with a serial fallback" >&2
		exit 1
	fi
done
if ! grep -Fq 'name: Prepare packaged compiler bridges' "$release_workflow" ||
	! grep -Fq 'current_toolchain="${RUNNER_TEMP}/blorp-current-toolchain"' "$release_workflow" ||
	! grep -Fq 'BLORP_COMPILER_BRIDGE_BIN="$current_toolchain/blorp"' "$release_workflow" ||
	! grep -Fq './blorp __compiler-bridge-prepare' "$release_workflow" ||
	! grep -Fq 'BLORP_RELEASE_PARSER_BRIDGE:' "$release_workflow" ||
	! grep -Fq 'name: Smoke packaged toolchain' "$release_workflow" ||
	! grep -Fq 'compiler_parser_bridge_cli.brp' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" compile' "$release_workflow" ||
	! grep -Fq '"$package_dir/blorp" purify --dry-run' "$release_workflow" ||
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
if grep -Fq 'blorp-bootstrap-compiler' "$release_workflow" ||
	grep -Fq '__compiler-host-compile-wrapper' "$release_workflow"
then
	echo "FAIL: release CI must not retain the retired bootstrap helper bundle" >&2
	exit 1
fi
for executable in $required_staged_toolchain; do
	if ! grep -Fq "            $executable" <<<"$release_prepare_step"; then
		echo "FAIL: release CI must stage $executable before preparing compiler bridges" >&2
		exit 1
	fi
done

benchmark_workflow=.github/workflows/benchmarks.yml
if ! grep -Fq 'gh run download "$run_id"' "$benchmark_workflow" ||
	! grep -Fq 'headSha == $sha' "$benchmark_workflow" ||
	! grep -Fq '.event == "push"' "$benchmark_workflow" ||
	grep -Fq 'make install' "$benchmark_workflow" ||
	grep -Fq 'Cache Blorp compiler bridge helpers' "$benchmark_workflow" ||
	grep -Fq 'Cache generated Blorp CLI' "$benchmark_workflow"
then
	echo "FAIL: benchmarks must reuse the successful CI toolchain for the checked-out commit" >&2
	exit 1
fi

for workflow in .github/workflows/ci.yml .github/workflows/release.yml; do
	if ! grep -Fq 'isolated-compiler' "$workflow" ||
		! grep -Fq '"$isolated_compiler_dir/blorp" compile --no-format' "$workflow"
	then
		echo "FAIL: $workflow must prove compile needs only the public binary" >&2
		exit 1
	fi
done

premerge_hygiene=$(sed -n '/run_drift_checks()/,/^}/p' scripts/premerge-gate)
if ! grep -Fq 'if [ "$run_quality" -eq 0 ]' <<<"$premerge_hygiene"; then
	echo "FAIL: premerge drift checks must not repeat hygiene after the quality gate" >&2
	exit 1
fi

echo "PASS: build and CI cache ownership is explicit"
