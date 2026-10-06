#!/usr/bin/env bash
# Behavioural checks of the build graph: they run the built compiler, the
# generator, `make -n` under different settings and the benchmark wrappers.
# They do not assert the text of the Makefile, the workflows or the scripts.

set -euo pipefail

cd "$(dirname "$0")/../../.."

relocation_probe=$(mktemp "${TMPDIR:-/tmp}/blorp-relocation-probe.XXXXXX")
trap 'rm -f "$relocation_probe"' EXIT
if ! blorp/build/_build/blorp-cli/blorp compile --no-format --no-embed-runtime \
	-o "$relocation_probe" \
	blorp/test/test_compiler/test_pipeline/codegen_audit/should_pass/compiler_lsp_stdio_transport.brp \
	>/dev/null
then
	echo "FAIL: the built compiler cannot emit relocated blorp/src/compiler modules" >&2
	exit 1
fi
if ! grep -Fq 'blorp_src_lsp_lsp_stdio_transport__CompilerStdioError' \
	"$relocation_probe" ||
	! grep -Eq 'blorp_compiler_stdin_read_raw\(brp_vn?_[A-Za-z0-9]+\)' "$relocation_probe" ||
	! grep -Eq 'blorp_compiler_stdout_write_all_raw\(brp_vn?_[A-Za-z0-9]+\)' "$relocation_probe"
then
	echo "FAIL: relocated LSP native operations did not reach C emission" >&2
	exit 1
fi
rm -f "$relocation_probe"
trap - EXIT

tracked_ocaml_files=$(
	git ls-files | grep -E '(^|/)(dune|dune-project)$|[.]ml(i)?$|[.]opam$|(^|/)opam[^/]*$' |
		grep -v '^benchmarks/ocaml/' || true
)
if [ -n "$tracked_ocaml_files" ]; then
	echo "FAIL: OCaml source and build files are allowed only as benchmark inputs" >&2
	printf '%s\n' "$tracked_ocaml_files" >&2
	exit 1
fi
make compiler-build-source-generator >/dev/null
generated_build_info=$(
	BLORP_BUILD_VERSION=1.2.3-test \
	BLORP_BUILD_COMMIT=0123456789abcdef \
	BLORP_BUILD_TARGET=test-target \
	BLORP_BUILD_CHANNEL=test-channel \
	BLORP_BUILD_DIRTY=false \
		blorp/build/_build/build-tools/generate-build-sources build-info blorp/build/VERSION
)
for expected_build_info in \
	'VERSION: String = "1.2.3-test"' \
	'VERSION_DESCRIPTION: String = "blorp 1.2.3-test\ncommit: 0123456789abcdef\ntarget: test-target\nchannel: test-channel\ndirty: false\nstd: embedded, hash " + embedded_std_digest'
do
	if ! grep -Fq "$expected_build_info" <<<"$generated_build_info"; then
		echo "FAIL: generated Blorp build metadata omitted $expected_build_info" >&2
		exit 1
	fi
done

cli_build_plan=$(
	unset BLORP_CLI_C_OPTIMIZATION BLORP_CC MAKEFLAGS MFLAGS
	make -n build-blorp-cli
)
release_cli_build_plan=$(
	unset BLORP_CC
	make -n BLORP_CLI_C_OPTIMIZATION=-O2 build-blorp-cli
)
local_runtime_object=$(grep -o 'runtime-[0-9a-f]\{64\}\.o' <<<"$cli_build_plan" | head -n 1)
release_runtime_object=$(grep -o 'runtime-[0-9a-f]\{64\}\.o' <<<"$release_cli_build_plan" | head -n 1)
if [ -z "$local_runtime_object" ] || [ -z "$release_runtime_object" ] ||
	[ "$local_runtime_object" != "$release_runtime_object" ]
then
	echo "FAIL: fast and release compiler builds must share the optimized runtime object" >&2
	exit 1
fi
debug_runtime_build_plan=$(
	unset BLORP_CC
	make -n -B BLORP_CLI_RUNTIME_C_OPTIMIZATION=-O0 prepare-blorp-cli-runtime
)
debug_runtime_object=$(
	grep -o 'runtime-[0-9a-f]\{64\}\.o' <<<"$debug_runtime_build_plan" | head -n 1
)
if [ -z "$debug_runtime_object" ] || [ "$debug_runtime_object" = "$local_runtime_object" ]
then
	echo "FAIL: an explicit runtime optimization override must get a distinct object" >&2
	exit 1
fi
runtime_object_path="blorp/build/_build/blorp-cli/$local_runtime_object"
runtime_object_probe_created=false
if [ ! -e "$runtime_object_path" ]; then
	mkdir -p "$(dirname "$runtime_object_path")"
	touch "$runtime_object_path"
	runtime_object_probe_created=true
	trap 'rm -f "$runtime_object_path"' EXIT
fi
for runtime_source in minicoro.h runtime.c runtime_decl.c; do
	runtime_source_path="blorp/src/lib/runtime/native/$runtime_source"
	runtime_timestamp_plan=$(
		unset BLORP_CC
		make -n -W "$runtime_source_path" prepare-blorp-cli-runtime
	)
	if grep -Fq 'clang "' <<<"$runtime_timestamp_plan"; then
		echo "FAIL: content-addressed runtime object must ignore $runtime_source timestamps" >&2
		exit 1
	fi
done
if [ "$runtime_object_probe_created" = true ]; then
	rm -f "$runtime_object_path"
	trap - EXIT
fi
diagnostic_build_plan=$(
	unset BLORP_CLI_C_OPTIMIZATION BLORP_CC MAKEFLAGS MFLAGS
	make -n BLORP_MEMORY_DIAGNOSTICS=1 compile-prepared-blorp-cli
)
normal_body_hash_recipe=$(grep -F 'new_hash=$(' <<<"$cli_build_plan")
diagnostic_body_hash_recipe=$(grep -F 'new_hash=$(' <<<"$diagnostic_build_plan")
normal_link_hash_recipe=$(grep -F 'link_hash=$(' <<<"$cli_build_plan")
diagnostic_link_hash_recipe=$(grep -F 'link_hash=$(' <<<"$diagnostic_build_plan")
if [ "$normal_body_hash_recipe" != "$diagnostic_body_hash_recipe" ] ||
	[ "$normal_link_hash_recipe" = "$diagnostic_link_hash_recipe" ]; then
	echo "FAIL: diagnostic mode must share Blorp CLI body objects and change the link cache key" >&2
	exit 1
fi
split_one_build_plan=$(
	unset BLORP_CLI_C_OPTIMIZATION BLORP_CC MAKEFLAGS MFLAGS
	make -n BLORP_CLI_C_SPLIT=1 compile-prepared-blorp-cli
)
split_one_body_hash_recipe=$(grep -F 'new_hash=$(' <<<"$split_one_build_plan")
if [ "$normal_body_hash_recipe" = "$split_one_body_hash_recipe" ]; then
	echo "FAIL: BLORP_CLI_C_SPLIT must change the Blorp CLI body cache key" >&2
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
	contract_workspace=${6:-$PWD}
	compiler_args="$benchmark_contract_root/$contract_name.compiler-args"
	cc_args="$benchmark_contract_root/$contract_name.cc-args"
	benchmark_output=$(
		PATH="$benchmark_fake_bin:$PATH" \
		BLORP_BENCHMARK_CACHE_DIR="$benchmark_contract_root/cache-$contract_name" \
		BLORP_BENCHMARK_USE_PREPARED_BRIDGES=0 \
		BLORP_COMPILER_BENCHMARK_COMPILER="$benchmark_fake_bin/compiler" \
		BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
		BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT="$contract_workspace" \
		BLORP_COMPILER_BRIDGE_BIN=/usr/bin/true \
		BLORP_FAKE_CC_ARGS="$cc_args" \
		BLORP_FAKE_COMPILER_ARGS="$compiler_args" \
		"$benchmark_entrypoint"
	)
	if [ "$benchmark_output" != "BENCHMARK_CONTRACT_SMOKE" ] ||
		[ "$(sed -n '1p' "$compiler_args")" != "compile" ] ||
		! grep -Fxq -- '--no-format' "$compiler_args" ||
		! grep -Fxq "$expected_source" "$compiler_args" ||
		! grep -Fxq -- "$expected_cc_optimization" "$cc_args" ||
		! grep -Fxq -- "-I$contract_workspace/blorp/src/compiler/stage_06_typecheck/graph" "$cc_args" ||
		! grep -Fxq -- "-I$contract_workspace/blorp/src/compiler/stage_06_typecheck/type_system" "$cc_args"
	then
		echo "FAIL: $benchmark_entrypoint must compile its expected fixture and compiler headers through the public CLI" >&2
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
	ctfe-typecheck \
	./benchmarks/compiler_ctfe_typecheck_profile \
	"$PWD/blorp/benchmark/compiler/compiler_ctfe_typecheck_profile.brp" \
	plain \
	-O2
assert_compiler_benchmark_contract \
	import-graph \
	./benchmarks/compiler_import_graph_profile \
	"$PWD/blorp/benchmark/compiler/compiler_import_graph_profile.brp" \
	plain \
	-O2
assert_compiler_benchmark_contract \
	module-binding \
	./benchmarks/compiler_module_binding_profile \
	"$PWD/blorp/benchmark/compiler/compiler_module_binding_profile.brp" \
	plain \
	-O2
assert_compiler_benchmark_contract \
	typecheck \
	./benchmarks/compiler_typecheck_profile \
	"$PWD/blorp/benchmark/compiler/compiler_typecheck_profile.brp" \
	profile \
	-O0
assert_compiler_benchmark_contract \
	core-flatten \
	./benchmarks/compiler_core_flatten_profile \
	"$PWD/blorp/benchmark/compiler/compiler_core_flatten_profile.brp" \
	profile \
	-O0

alternate_benchmark_workspace="$benchmark_contract_root/alternate-workspace"
mkdir -p \
	"$alternate_benchmark_workspace/blorp/src/compiler" \
	"$alternate_benchmark_workspace/blorp/benchmark/compiler" \
	"$alternate_benchmark_workspace/standard_library/src"
cp blorp.toml "$alternate_benchmark_workspace/blorp.toml"
cp \
	blorp/benchmark/compiler/compiler_import_graph_profile.brp \
	"$alternate_benchmark_workspace/blorp/benchmark/compiler/compiler_import_graph_profile.brp"
assert_compiler_benchmark_contract \
	import-graph-alternate-workspace \
	./benchmarks/compiler_import_graph_profile \
	"$alternate_benchmark_workspace/blorp/benchmark/compiler/compiler_import_graph_profile.brp" \
	plain \
	-O2 \
	"$alternate_benchmark_workspace"

rm -rf "$benchmark_contract_root"
trap - EXIT

echo "PASS: build configuration behaves as expected"
