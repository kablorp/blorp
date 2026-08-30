#!/usr/bin/env bash
# Regression tests for the top-level build graph and CI cache ownership.

set -euo pipefail

cd "$(dirname "$0")/../../.."

build_plan=$(make -n build)
if ! grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$build_plan"; then
	echo "FAIL: make build must build the self-hosted Blorp compiler" >&2
	printf '%s\n' "$build_plan" >&2
	exit 1
fi
if [ -e compiler/blorp ]; then
	echo "FAIL: the retired compiler/blorp directory must not return" >&2
	exit 1
fi
if ! grep -Fq 'bootstrap_layout="blorp/build/_build/blorp-cli/bootstrap-layout"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/blorp/src/main.brp"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/src"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/compile"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/check"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/run"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/format/engine"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/purify"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/lint"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/test"' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/package"' <<<"$build_plan" ||
	! grep -Fq 'for source in blorp/src/purify/*.brp' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/purify/$(basename "$source")"' <<<"$build_plan" ||
	! grep -Fq 'for source in blorp/src/lint/*.brp' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/lint/$(basename "$source")"' <<<"$build_plan" ||
	! grep -Fq 'for source in blorp/src/test/*.brp' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/test/$(basename "$source")"' <<<"$build_plan" ||
	! grep -Fq 'for source in blorp/src/package/*.brp' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/package/$(basename "$source")"' <<<"$build_plan" ||
	! grep -Fq 'cp -R blorp/src/compiler/. "$bootstrap_layout/compiler/blorp/src/"' <<<"$build_plan" ||
	! grep -Fq 'cp -R blorp/src/lsp/. "$bootstrap_layout/compiler/blorp/src/stage_12_lsp/"' <<<"$build_plan" ||
	! grep -Fq 'find blorp/src/lsp -name' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/src/stage_12_lsp/$relative"' <<<"$build_plan" ||
	! grep -Fq '\.\./\.\./lib/#\1../../../lib/#' <<<"$build_plan" ||
	! grep -Fq 'for source in blorp/src/format/*.brp' <<<"$build_plan" ||
	! grep -Fq 'destination="$bootstrap_layout/compiler/blorp/format/$(basename "$source")"' <<<"$build_plan" ||
	! grep -Fq 'cp blorp/src/format/engine/*.brp "$bootstrap_layout/compiler/blorp/format/engine/"' <<<"$build_plan" ||
	! grep -Fq 'run/#\1../../compiler/blorp/run/#' <<<"$build_plan" ||
	! grep -Fq 'purify/#\1../../compiler/blorp/purify/#' <<<"$build_plan" ||
	! grep -Fq 'lint/#\1../../compiler/blorp/lint/#' <<<"$build_plan" ||
	! grep -Fq 'test/#\1../../compiler/blorp/test/#' <<<"$build_plan" ||
	! grep -Fq 'package/#\1../../compiler/blorp/package/#' <<<"$build_plan" ||
	! grep -Fq 'lsp/#\1../../compiler/blorp/src/stage_12_lsp/#' <<<"$build_plan" ||
	! grep -Fq '"$bootstrap_layout/compiler/blorp/lib"' <<<"$build_plan" ||
	! grep -Fq 'transition-blorp' <<<"$build_plan" ||
	! grep -Fq '"$transition_bin" compile --no-format' <<<"$build_plan" ||
	! grep -Fq 'blorp/src/main.brp' <<<"$build_plan" ||
	! grep -Fq 'command -v "$bootstrap_compiler"' <<<"$build_plan"
then
	echo "FAIL: the pinned compiler needs the complete isolated transition layout" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/format"' <<<"$build_plan"; then
	echo "FAIL: formatter transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/purify"' <<<"$build_plan"; then
	echo "FAIL: purify transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/lint"' <<<"$build_plan"; then
	echo "FAIL: lint transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/test"' <<<"$build_plan"; then
	echo "FAIL: test-command transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/package"' <<<"$build_plan"; then
	echo "FAIL: package transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
if grep -Fq 'ln -s "$repo_root/blorp/src/lsp"' <<<"$build_plan"; then
	echo "FAIL: LSP transition sources require import rewriting, not a symlink" >&2
	exit 1
fi
format_transition_block=$(
	sed -n '/for source in blorp\/src\/format\/[*][.]brp/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./compiler/#\1../src/#' <<<"$format_transition_block"; then
	echo "FAIL: formatter transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi
purify_transition_block=$(
	sed -n '/for source in blorp\/src\/purify\/[*][.]brp/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./compiler/#\1../src/#' <<<"$purify_transition_block"; then
	echo "FAIL: purify transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi
lint_transition_block=$(
	sed -n '/for source in blorp\/src\/lint\/[*][.]brp/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./compiler/#\1../src/#' <<<"$lint_transition_block"; then
	echo "FAIL: lint transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi
test_transition_block=$(
	sed -n '/for source in blorp\/src\/test\/[*][.]brp/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./compiler/#\1../src/#' <<<"$test_transition_block"; then
	echo "FAIL: test-command transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi
package_transition_block=$(
	sed -n '/for source in blorp\/src\/package\/[*][.]brp/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./compiler/#\1../src/#' <<<"$package_transition_block"; then
	echo "FAIL: package transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi
lsp_transition_block=$(
	sed -n '/find blorp\/src\/lsp -name/,/done/p' <<<"$build_plan"
)
if ! grep -Fq '\.\./\.\./compiler/#\1../../#' <<<"$lsp_transition_block"; then
	echo "FAIL: LSP transition sources must rewrite canonical compiler imports" >&2
	exit 1
fi

relocation_probe=$(mktemp "${TMPDIR:-/tmp}/blorp-relocation-probe.XXXXXX")
trap 'rm -f "$relocation_probe"' EXIT
if ! blorp/build/_build/blorp-cli/blorp compile --no-format --no-embed-runtime \
	-o "$relocation_probe" \
	blorp/test/compiler/pipeline/codegen_audit/should_pass/compiler_lsp_stdio_transport.brp \
	>/dev/null
then
	echo "FAIL: the built compiler cannot emit relocated blorp/src/compiler modules" >&2
	exit 1
fi
if ! grep -Fq 'blorp_src_lsp_lsp_stdio_transport__CompilerStdioError' \
	"$relocation_probe" ||
	! grep -Fq 'blorp_compiler_stdin_read_raw(max_bytes)' "$relocation_probe" ||
	! grep -Fq 'blorp_compiler_stdout_write_all_raw(data)' "$relocation_probe"
then
	echo "FAIL: relocated LSP native operations did not reach C emission" >&2
	exit 1
fi
if grep -Fq 'compiler_blorp_src_stage_12_lsp_lsp_stdio_transport__CompilerStdioError' \
	"$relocation_probe"
then
	echo "FAIL: the built compiler still emits the retired compiler/blorp identity" >&2
	exit 1
fi
tracked_ocaml_files=$(
	git ls-files | grep -E '(^|/)(dune|dune-project)$|[.]ml(i)?$|[.]opam$|(^|/)opam[^/]*$' |
		grep -v '^benchmarks/ocaml/' || true
)
if [ -n "$tracked_ocaml_files" ]; then
	echo "FAIL: OCaml source and build files are allowed only as benchmark inputs" >&2
	printf '%s\n' "$tracked_ocaml_files" >&2
	exit 1
fi
tracked_ocaml_references=$(
	git grep -n -i -E 'ocaml|opam|dune|alcotest|[.]ml(i)?([^[:alnum:]_]|$)' -- . \
		':!benchmarks/**' \
		':!.github/workflows/benchmarks.yml' \
		':!blorp/test/build/test_build_configuration.sh' \
		':!blorp/test/build/test_scripts_test_harness.sh' || true
)
if [ -n "$tracked_ocaml_references" ]; then
	echo "FAIL: OCaml references are allowed only in benchmark inputs and policy" >&2
	printf '%s\n' "$tracked_ocaml_references" >&2
	exit 1
fi
clean_plan=$(make -n clean)
if ! grep -Fq 'blorp/build/_build/build-tools' <<<"$clean_plan"; then
	echo "FAIL: make clean must own current build tools" >&2
	exit 1
fi
if ! grep -Fq 'scripts/clean-retired-layout' <<<"$clean_plan"; then
	echo "FAIL: make clean must remove known generated artifacts from retired roots" >&2
	exit 1
fi

retired_layout=$(mktemp -d "${TMPDIR:-/tmp}/blorp-retired-layout.XXXXXX")
trap 'rm -rf "$retired_layout"' EXIT
mkdir -p \
	"$retired_layout/compiler/_build" \
	"$retired_layout/compiler/_coverage" \
	"$retired_layout/tests/nested/__pycache__" \
	"$retired_layout/tests/nested/generated"
printf 'build artifact\n' >"$retired_layout/compiler/_build/output"
printf 'coverage artifact\n' >"$retired_layout/compiler/_coverage/output"
printf 'cache artifact\n' >"$retired_layout/tests/nested/__pycache__/module.pyc"
printf '/* Generated by blorp compiler */\n' >"$retired_layout/tests/nested/generated/program.c"
printf 'user C source\n' >"$retired_layout/tests/nested/user_source.c"
printf '// example: /* Generated by blorp compiler */\n' \
	>"$retired_layout/tests/nested/generated_header_example.c"
printf 'user source\n' >"$retired_layout/compiler/user_source.brp"
scripts/clean-retired-layout "$retired_layout"
if [ -e "$retired_layout/compiler/_build" ] || \
	[ -e "$retired_layout/compiler/_coverage" ] || \
	[ -e "$retired_layout/tests/nested/__pycache__" ] || \
	[ -e "$retired_layout/tests/nested/generated/program.c" ]; then
	echo "FAIL: retired-layout cleanup left recognized generated artifacts" >&2
	exit 1
fi
if [ ! -f "$retired_layout/tests/nested/user_source.c" ] || \
	[ ! -f "$retired_layout/tests/nested/generated_header_example.c" ] || \
	[ ! -f "$retired_layout/compiler/user_source.brp" ]; then
	echo "FAIL: retired-layout cleanup removed an unknown user file" >&2
	exit 1
fi
rm -rf "$retired_layout"
trap - EXIT

if [ ! -f blorp/tool/generate_build_sources.brp ]; then
	echo "FAIL: the compiler build-source generator is missing" >&2
	exit 1
fi
make compiler-build-source-generator >/dev/null

if [ ! -f blorp/build/VERSION ] || [ "$(wc -l < blorp/build/VERSION | tr -d ' ')" -ne 1 ]; then
	echo "FAIL: blorp/build/VERSION must be the single-line compiler version source" >&2
	exit 1
fi
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
if grep -R -n 'BLORP_FRONTEND_PARSER' \
	blorp/src/compiler scripts benchmarks Makefile --exclude-dir=results
then
	echo "FAIL: the retired frontend parser selector remains active" >&2
	exit 1
fi
if grep -Fq '../stage_10_backend' \
	blorp/src/compiler/stage_09_core/pipeline.brp
then
	echo "FAIL: Stage 09 Core pipeline must not depend on the Stage 10 backend" >&2
	exit 1
fi
all_plan=$(make -n all)
if grep -Fq 'bin/blorp format --check' <<<"$all_plan"; then
	echo "FAIL: ordinary make must not execute formatter warm-up" >&2
	exit 1
fi

for gate_target in compiler-blorp-test compiler-tools-test lsp-test package-test; do
	gate_plan=$(make -n "$gate_target")
	if ! grep -Fq "scripts/test ${gate_target%-test} --serial" <<<"$gate_plan"; then
		echo "FAIL: make $gate_target must expose its scripts/test gate" >&2
		exit 1
	fi
done

for cmake_gate in \
	'add_blorp_test(blorp.compiler-blorp compiler-blorp)' \
	'add_blorp_test(blorp.compiler-tools compiler-tools)' \
	'add_blorp_test(blorp.lsp lsp)' \
	'add_blorp_test(blorp.package package)'
do
	if ! grep -Fq "$cmake_gate" CMakeLists.txt; then
		echo "FAIL: CMake must expose $cmake_gate" >&2
		exit 1
	fi
done

if ! grep -Fq 'blorp/test/lib/run_blorp_check_fixtures.py' scripts/test; then
	echo "FAIL: compiler-blorp must retain the production Blorp check fixture runner" >&2
	exit 1
fi
if ! grep -Fq 'blorp/test/tool/test_compiler_tool_fixtures.py' scripts/test ||
	! grep -Fq 'compiler-blorp compiler-tools std-check' scripts/premerge-gate
then
	echo "FAIL: public compiler tool fixtures must retain a maintained premerge gate" >&2
	exit 1
fi

stage_two_runner=blorp/test/cli/test_cli_stage_two.sh
if ! grep -Fq 'PASS: suite counters are stable across repeat' \
	"$stage_two_runner"; then
	echo "FAIL: stage-two smoke must assert the exact session-counter route" >&2
	exit 1
fi
if grep -Fq 'echo "$smoke_output" | grep -qF' "$stage_two_runner"; then
	echo "FAIL: stage-two smoke matching must not use an early-closing pipe" >&2
	exit 1
fi
if ! grep -Fq -- '-Iblorp/src/lib' "$stage_two_runner"; then
	echo "FAIL: stage-two compiler must find shared native headers" >&2
	exit 1
fi

# The quality gate may intentionally validate a restored release candidate at
# another optimization level. Check Make's local default independently of that
# ambient override, including recursive Make's command-line propagation; the
# explicit release override is covered below.
cli_build_plan=$(
	unset BLORP_CLI_C_OPTIMIZATION MAKEFLAGS MFLAGS
	make -n build-blorp-cli
)
if ! grep -Fq 'set -e;' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must stop after a failed compiler command" >&2
	exit 1
fi
if ! grep -Fq 'rm -f "blorp/build/_build/blorp-cli/blorp_cli_main.c"' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must remove stale generated C before compilation" >&2
	exit 1
fi
if ! grep -Fq 'tmp_bin="blorp/build/_build/blorp-cli/blorp.tmp"' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must publish the executable atomically" >&2
	exit 1
fi
if ! grep -Fq '[ ! -s "blorp/build/_build/blorp-cli/blorp_cli_main.c" ]' <<<"$cli_build_plan"; then
	echo "FAIL: a missing generated C artifact must invalidate the Blorp CLI build" >&2
	exit 1
fi
if ! grep -Fq 'blorp/build/_build/blorp-cli/runtime_sources.c' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must link the generated runtime source provider" >&2
	exit 1
fi
if ! grep -Fq '$(BLORP_EMBEDDED_STD_SOURCE)' Makefile; then
	echo "FAIL: the generated embedded std source must remain a Blorp CLI prerequisite" >&2
	exit 1
fi
canonical_embedded_std_source=blorp/src/compiler/stage_01_file_io/embedded_std.brp
configured_embedded_std_source=$(
	make --no-print-directory -s -f - print-embedded-std-source <<'MAKE'
include Makefile
.PHONY: print-embedded-std-source
print-embedded-std-source:
	@printf '%s\n' '$(BLORP_EMBEDDED_STD_SOURCE)'
MAKE
)
noncanonical_embedded_std_sources=$(
	find blorp/src/compiler -type f -name '*embedded_std*.brp' \
		! -path "$canonical_embedded_std_source" -print
)
if [ "$configured_embedded_std_source" != "$canonical_embedded_std_source" ] ||
	[ -n "$noncanonical_embedded_std_sources" ]
then
	echo "FAIL: the Blorp CLI must retain one canonical generated embedded std source" >&2
	exit 1
fi
if ! grep -Fq '$(BLORP_BUILD_INFO_SOURCE)' Makefile; then
	echo "FAIL: generated Blorp build metadata must remain a Blorp CLI prerequisite" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_COMPILER_RUNTIME_SOURCES=1' <<<"$cli_build_plan"; then
	echo "FAIL: the compiler-only runtime source hooks must be explicitly enabled" >&2
	exit 1
fi
if ! grep -Fq 'cc "-O0" -fwrapv -pipe -w' <<<"$cli_build_plan"; then
	echo "FAIL: local Blorp CLI builds must retain the fast -O0 default" >&2
	exit 1
fi
release_cli_build_plan=$(make -n BLORP_CLI_C_OPTIMIZATION=-Og build-blorp-cli)
if ! grep -Fq 'cc "-Og" -fwrapv -pipe -w' <<<"$release_cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must accept the release C optimization level" >&2
	exit 1
fi
local_runtime_object=$(grep -o 'runtime-[0-9a-f]\{64\}\.o' <<<"$cli_build_plan" | head -n 1)
release_runtime_object=$(grep -o 'runtime-[0-9a-f]\{64\}\.o' <<<"$release_cli_build_plan" | head -n 1)
if [ -z "$local_runtime_object" ] || [ -z "$release_runtime_object" ] ||
	[ "$local_runtime_object" = "$release_runtime_object" ]
then
	echo "FAIL: the runtime object identity must change with its C optimization level" >&2
	exit 1
fi
cli_cache_identity=$(sed -n '/new_hash=/,/old_hash=/p' Makefile)
if ! grep -Fq '$(BLORP_CLI_C_OPTIMIZATION)' <<<"$cli_cache_identity"; then
	echo "FAIL: the Blorp CLI cache identity must include its C optimization level" >&2
	exit 1
fi
if ! grep -Fq "find blorp/src -name '*.brp' -type f -print" <<<"$cli_build_plan" ||
	grep -Fq "find tools/formatter -name '*.brp' -type f -print" <<<"$cli_build_plan"; then
	echo "FAIL: formatter sources must participate once through the canonical Blorp source root" >&2
	exit 1
fi
if ! grep -Fq 'python3 -m unittest blorp/test/runtime/test_runtime_allocator_stats.py' Makefile; then
	echo "FAIL: hygiene-check must include the optimized runtime allocator regression" >&2
	exit 1
fi
if ! grep -Fq -- '--print-path' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must resolve the pinned public compiler" >&2
	exit 1
fi
if ! grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$cli_build_plan"; then
	echo "FAIL: the Blorp CLI build must invoke the pinned public compile command" >&2
	exit 1
fi
direct_compiler_benchmark=benchmarks/compiler_record_layout
if ! grep -Fq 'compile --' "$direct_compiler_benchmark"; then
	echo "FAIL: $direct_compiler_benchmark must compile through the current public CLI" >&2
	exit 1
fi

compiler_benchmark_runner=benchmarks/compiler_blorp_benchmark_runner
for compiler_benchmark in \
	benchmarks/compiler_ctfe_typecheck_profile \
	benchmarks/compiler_import_graph_profile \
	benchmarks/compiler_module_binding_profile \
	benchmarks/compiler_typecheck_profile
do
	if ! grep -Eq '^exec "[$]script_dir/compiler_blorp_benchmark_runner" \\$' \
		"$compiler_benchmark"
	then
		echo "FAIL: $compiler_benchmark must delegate compilation to the shared runner" >&2
		exit 1
	fi
done
if ! grep -Eq \
	'^compiler=.*[$]workspace_root/blorp/build/_build/blorp-cli/blorp' \
	"$compiler_benchmark_runner"
then
	echo "FAIL: the shared compiler benchmark runner must default to the selected workspace Blorp CLI" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_COMPILER_BENCHMARK_WORKSPACE_ROOT' "$compiler_benchmark_runner" ||
	! grep -Fq -- "-name '*.h'" "$compiler_benchmark_runner"
then
	echo "FAIL: the shared compiler benchmark runner must bind compiler headers to an explicit workspace and cache identity" >&2
	exit 1
fi
if [ ! -f blorp/benchmark/compiler/compiler_typecheck_worker.brp ] ||
	[ -e blorp/src/compiler/stage_12_cli/typecheck_bridge_cli.brp ]
then
	echo "FAIL: the standalone typecheck worker must be owned by compiler benchmarks" >&2
	exit 1
fi
if ! grep -Fq 'format/#\1../../compiler/blorp/format/' Makefile
then
	echo "FAIL: the bootstrap root must rewrite the format command owner explicitly" >&2
	exit 1
fi
if ! grep -Fq "find blorp/src -name '*.h' -type f -print" Makefile ||
	! grep -Fq 'blorp/src/main_output.h' blorp/build/_build/blorp-cli/build-inputs.sha256
then
	echo "FAIL: the CLI build cache must own headers outside the compiler subtree" >&2
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
if ! grep -Fq 'name: Test benchmark-only typecheck worker' \
	.github/workflows/ci-platform.yml ||
	! grep -Fq 'benchmarks/compiler_typecheck_memory \' \
	.github/workflows/ci-platform.yml
then
	echo "FAIL: required CI must compile, link, and run the benchmark-only typecheck worker" >&2
	exit 1
fi
for obsolete_build_input in \
	BLORP_COMPILER_BRIDGE_BIN \
	BLORP_COMPILER_RENDERER_BRIDGE_BIN \
	BLORP_COMPILER_PARSER_BRIDGE_BIN \
	BLORP_COMPILER_TYPECHECK_BRIDGE_BIN \
	BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE
do
	if grep -Fq "$obsolete_build_input" <<<"$cli_build_plan"; then
		echo "FAIL: the Blorp CLI build must not retain obsolete bootstrap input $obsolete_build_input" >&2
		exit 1
	fi
done
if ! grep -Fq "sed -n '/^# Build the public Blorp executable/,/^# Run the top-level local test gate/p' Makefile" \
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
	'new_hash=$(printf '\''%s\n%s\n%s\n'\'' "$source_hash" "$recipe_hash" "-O0"' \
	<<<"$cli_build_plan"
then
	echo "FAIL: source, recipe, and C optimization must determine the Blorp CLI cache key" >&2
	exit 1
fi

if ! grep -Fxq 'hygiene-check: build-blorp-cli' Makefile; then
	echo "FAIL: hygiene checks must inspect generated C from the current CLI build" >&2
	exit 1
fi

projection_check=scripts/check-c-symbol-projection-boundary
if grep -Eq '(^|[[:space:]])rg([[:space:]]|$)' "$projection_check"; then
	echo "FAIL: C symbol projection checks must not depend on optional ripgrep tooling" >&2
	exit 1
fi

install_plan=$(make -n install)
if ! grep -Fq '"$bootstrap_compiler" compile --no-format' <<<"$install_plan"; then
	echo "FAIL: install must retain the public Blorp CLI build" >&2
	exit 1
fi
if ! grep -Fq 'cp "blorp/build/_build/blorp-cli/blorp" "bin/blorp"' <<<"$install_plan"
then
	echo "FAIL: install must publish the public Blorp compiler" >&2
	exit 1
fi
bootstrap_manifest=blorp/build/bootstrap.env
if [ ! -f "$bootstrap_manifest" ]; then
	echo "FAIL: the compiler bootstrap must have one checked-in manifest" >&2
	exit 1
fi

# The manifest is checked-in shell data so the bootstrap wrapper and CI can
# share one release identity without maintaining a second parser.
# shellcheck source=../blorp/build/bootstrap.env
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
	single | direct) ;;
	*)
		echo "FAIL: $bootstrap_manifest must pin a supported single-binary compiler layout" >&2
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
	.github/workflows/ci-platform.yml \
	.github/workflows/premerge.yml \
	.github/workflows/release.yml
do
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
	if grep -Fq 'scripts/blorp-compiler-bootstrap --print-path' "$workflow"; then
		echo "FAIL: $workflow must let the first real compiler use populate the bootstrap cache" >&2
		exit 1
	fi
	if ! grep -Fq "hashFiles('blorp/src/**'" "$workflow"; then
		echo "FAIL: $workflow must invalidate the generated CLI for every source-owner change" >&2
		exit 1
	fi
done
if ! grep -Fq 'ocaml-nox' .github/workflows/benchmarks.yml ||
	grep -Eqi 'setup-cached-ocaml|OCAML_COMPILER|opam exec|opam switch' \
		.github/workflows/benchmarks.yml
then
	echo "FAIL: benchmarks must isolate their OCaml comparison compiler from production tooling" >&2
	exit 1
fi

if ! grep -Fq 'mkdir -p bin' .github/workflows/benchmarks.yml ||
	! grep -Fq 'cp "$binary_path" bin/blorp' .github/workflows/benchmarks.yml
then
	echo "FAIL: benchmark workflow must create bin/ before installing its compiler" >&2
	exit 1
fi

ci_workflow=.github/workflows/ci.yml
ci_platform_workflow=.github/workflows/ci-platform.yml
ubuntu_call=$(sed -n '/^  ubuntu:/,/^  linux_arm:/p' "$ci_workflow")
arm_call=$(sed -n '/^  linux_arm:/,/^  macos:/p' "$ci_workflow")
macos_call=$(sed -n '/^  macos:/,$p' "$ci_workflow")
compiler_blorp_shard_one=$(sed -n '/"scope": "compiler-blorp"/,/"scope": "compiler-blorp-2"/p' "$ci_workflow")
compiler_blorp_shard_two=$(sed -n '/"scope": "compiler-blorp-2"/,/"scope": "product"/p' "$ci_workflow")
compiler_quality_lane=$(sed -n '/"scope": "compiler-internal"/,/"scope": "compiler-blorp"/p' "$ci_workflow")
ci_build_job=$(sed -n '/^  build-toolchain:/,/^  test:/p' "$ci_platform_workflow")
ci_test_job=$(sed -n '/^  test:/,/^  package-tested-toolchain:/p' "$ci_platform_workflow")
ci_package_job=$(sed -n '/^  package-tested-toolchain:/,$p' "$ci_platform_workflow")
if ! grep -Fq 'timeout-minutes: ${{ matrix.timeout_minutes }}' "$ci_platform_workflow"; then
	echo "FAIL: required CI must give each independent gate group an explicit budget" >&2
	exit 1
fi
if ! grep -Fq 'BLORP_BUILD_VERSION: ${{ steps.release-meta.outputs.version }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_BUILD_VERSION: ${{ needs.build-toolchain.outputs.version }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_BUILD_COMMIT: ${{ needs.build-toolchain.outputs.source_sha }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_BUILD_TARGET: ${{ needs.build-toolchain.outputs.target }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_BUILD_CHANNEL: ${{ needs.build-toolchain.outputs.channel }}' "$ci_platform_workflow" ||
	! grep -Fq 'echo "BLORP_BUILD_VERSION=$version"' "$ci_platform_workflow" ||
	! grep -Fq '>> "$GITHUB_ENV"' "$ci_platform_workflow" ||
	! grep -Fq 'name: Package tested toolchain' "$ci_platform_workflow" ||
	! grep -Fq 'name: Smoke tested compiler binary' "$ci_platform_workflow" ||
	! grep -Fq 'grep -Fxq "blorp ${BLORP_RELEASE_VERSION}"' "$ci_platform_workflow" ||
	! grep -Fq 'grep -Fxq "commit: ${BLORP_RELEASE_COMMIT}"' "$ci_platform_workflow" ||
	! grep -Fq 'grep -Fxq "target: ${BLORP_RELEASE_TARGET}"' "$ci_platform_workflow" ||
	! grep -Fq 'grep -Fxq "channel: ${BLORP_RELEASE_CHANNEL}"' "$ci_platform_workflow" ||
	! grep -Fq 'grep -Fxq "dirty: false"' "$ci_platform_workflow" ||
	! grep -Fq '"$isolated_compiler_dir/blorp" purify --dry-run' "$ci_platform_workflow" ||
	! grep -Fq 'name: Upload tested compiler binary' "$ci_platform_workflow" ||
	! grep -Fq 'name: blorp-${{ needs.build-toolchain.outputs.target }}' "$ci_platform_workflow" ||
	! grep -Fq 'path: dist/blorp-${{ needs.build-toolchain.outputs.target }}' "$ci_platform_workflow" ||
	! grep -Fq 'build-toolchain:' "$ci_platform_workflow" ||
	! grep -Fq 'needs: build-toolchain' "$ci_platform_workflow" ||
	! grep -Fq 'needs: [build-toolchain, test]' "$ci_platform_workflow" ||
	! grep -Fq 'name: ci-toolchain-${{ needs.build-toolchain.outputs.target }}' "$ci_platform_workflow" ||
	! grep -Fq 'bin/blorp \' "$ci_platform_workflow" ||
	[ "$(grep -Fc 'test -x bin/blorp' "$ci_platform_workflow")" -ne 2 ] ||
	! grep -Fq 'blorp/build/_build/blorp-cli/blorp \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/blorp_cli_main.c \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/runtime_sources.c \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/inputs.sha256 \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/build-inputs.sha256 \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/blorp.sha256 \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/build/_build/blorp-cli/embedded-inputs.sha256 \' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/src/compiler/stage_01_file_io/embedded_std.brp' "$ci_platform_workflow" ||
	! grep -Fq 'blorp/src/compiler/stage_01_file_io/compiler_build_info.brp' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_CLI_C_OPTIMIZATION: -Og' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_COMPILER_TEST_SHARD_INDEX: ${{ matrix.compiler_test_shard_index }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_COMPILER_TEST_SHARD_COUNT: ${{ matrix.compiler_test_shard_count }}' "$ci_platform_workflow" ||
	! grep -Fq 'BLORP_COMPILER_TEST_PROGRESS: ${{ matrix.compiler_test_progress }}' "$ci_platform_workflow" ||
	! grep -Fq 'bash scripts/test --no-build --serial ${{ matrix.gates }}' "$ci_platform_workflow" ||
	! grep -Fq 'uses: ./.github/workflows/ci-platform.yml' <<<"$ubuntu_call" ||
	! grep -Fq 'runner: ubuntu-latest' <<<"$ubuntu_call" ||
	! grep -Fq '"scope": "compiler-internal"' <<<"$ubuntu_call" ||
	! grep -Fq '"gates": "compiler-blorp"' <<<"$ubuntu_call" ||
	! grep -Fq '"gates": "runtime leak doctest cli lsp package"' <<<"$ubuntu_call" ||
	! grep -Fq 'runner: ubuntu-24.04-arm' <<<"$arm_call" ||
	! grep -Fq 'runner: macos-15' <<<"$macos_call" ||
	! grep -Fq '"gates": "runtime leak cli lsp"' <<<"$arm_call" ||
	! grep -Fq '"gates": "runtime leak cli lsp"' <<<"$macos_call"
then
	echo "FAIL: main CI must isolate each platform while qualifying one shared per-platform toolchain" >&2
	exit 1
fi
if grep -Fxq '            blorp \' "$ci_platform_workflow"; then
	echo "FAIL: the CI toolchain artifact must archive bin/blorp, not the blorp source directory" >&2
	exit 1
fi
if grep -Fq 'scripts/target-triple' <<<"$ci_test_job" ||
	grep -Fq 'scripts/target-triple' <<<"$ci_package_job" ||
	grep -Fq 'bin/blorp check --no-format blorp/src/main.brp' <<<"$ci_test_job" ||
	grep -Fq 'blorp/build/_build/blorp-cli \' <<<"$ci_build_job" ||
	grep -Eq 'apt-get install.*[[:space:]]m4([[:space:]]|$)' <<<"$ci_package_job" ||
	! grep -Fq '"$isolated_compiler_dir/blorp" compile --no-format' <<<"$ci_package_job" ||
	! grep -Fq 'release_binary="$PWD/dist/blorp-${BLORP_RELEASE_TARGET}"' <<<"$ci_package_job" ||
	grep -Fq -- '-o "$package_root/empty_main.c"' <<<"$ci_package_job"
then
	echo "FAIL: platform CI must not repeat metadata, compiler checks, package compiles, or broad build artifacts" >&2
	exit 1
fi
if [ "$(grep -Fc '"gates": "compiler-blorp"' <<<"$ubuntu_call")" -ne 2 ] ||
	[ "$(grep -Fc '"compiler_test_shard_count": 2' <<<"$ubuntu_call")" -ne 2 ] ||
	[ "$(grep -Fc '"compiler_test_shard_index": 1' <<<"$ubuntu_call")" -ne 1 ] ||
	[ "$(grep -Fc '"compiler_test_shard_index": 2' <<<"$ubuntu_call")" -ne 1 ] ||
	[ "$(grep -Fc '"compiler_test_progress": 1' <<<"$ubuntu_call")" -ne 2 ] ||
	[ "$(grep -Fc '"run_stage_two": true' <<<"$ubuntu_call")" -ne 1 ] ||
	! grep -Fq '"scope": "compiler-blorp"' <<<"$compiler_blorp_shard_one" ||
	! grep -Fq '"run_stage_two": true' <<<"$compiler_blorp_shard_two"
then
	echo "FAIL: Ubuntu CI must preserve the compiler-blorp check while sharding its corpus and running stage two once" >&2
	exit 1
fi
if [ "$(grep -Fc '"run_quality_checks": true' "$ci_workflow")" -ne 1 ] ||
	! grep -Fq '"gates": ""' <<<"$compiler_quality_lane" ||
	! grep -Fq 'name: Run quality checks' <<<"$ci_test_job" ||
	! grep -Fq 'name: Test benchmark-only typecheck worker' <<<"$ci_test_job" ||
	grep -Fq 'name: Run quality checks' <<<"$ci_build_job"
then
	echo "FAIL: Ubuntu CI must retain an independent Blorp-owned compiler quality lane" >&2
	exit 1
fi
if grep -Eq '^  (ubuntu-status|linux_arm_status|macos-status):' "$ci_workflow"; then
	echo "FAIL: main CI must not add no-op compatibility status jobs" >&2
	exit 1
fi
for production_path in \
	scripts/test \
	scripts/package-release \
	scripts/install-dev \
	.github/workflows/ci.yml \
	.github/workflows/ci-platform.yml \
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
premerge_workflow=.github/workflows/premerge.yml
if ! grep -Fq 'BLORP_COMPILER_TEST_TIMEOUT: 180' "$premerge_workflow"; then
	echo "FAIL: premerge CI must preserve the measured compiler-suite timeout" >&2
	exit 1
fi
if ! grep -Fq 'compiler_test_timeout="${BLORP_COMPILER_TEST_TIMEOUT:-180}"' scripts/premerge-gate ||
	! grep -Fq '"BLORP_COMPILER_TEST_TIMEOUT=$compiler_test_timeout"' scripts/premerge-gate
then
	echo "FAIL: local premerge must preserve the measured compiler-suite timeout" >&2
	exit 1
fi
premerge_test_suites=$(sed -n '/run_test_suites()/,/^}/p' scripts/premerge-gate)
if ! grep -Fq 'compiler-blorp compiler-tools std-check runtime leak doctest cli-deep lsp' <<<"$premerge_test_suites" ||
	! grep -Fq 'blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp' scripts/premerge-gate
then
	echo "FAIL: premerge must retain compiler, tool, runtime, and direct codegen coverage" >&2
	exit 1
fi
if [ "$(grep -Fc 'BLORP_COMPILER_TEST_TIMEOUT=${BLORP_COMPILER_TEST_TIMEOUT:-180}' scripts/docker-gate)" -ne 2 ]; then
	echo "FAIL: Docker premerge must forward the measured compiler-suite timeout" >&2
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
		! grep -Fxq -- "-I$contract_workspace/blorp/src/compiler/stage_06_typecheck/graph" "$cc_args"
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
	"$alternate_benchmark_workspace/std"
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

release_workflow=.github/workflows/release.yml
ci_build_step=$(sed -n '/name: Build compiler/,/name: Bundle compiler candidate/p' .github/workflows/ci-platform.yml)
release_build_job=$(sed -n '/^  build:/,/^  publish:/p' "$release_workflow")
release_publish_job=$(sed -n '/^  publish:/,$p' "$release_workflow")
release_dev_ci_step=$(sed -n '/name: Resolve latest successful main CI/,/name: Checkout source/p' "$release_workflow")
release_compiler_build_step=$(sed -n '/name: Build compiler/,/name: Package binary/p' "$release_workflow")
release_dev_source_step=$(sed -n '/name: Check dev release authorization/,/name: Validate release assets/p' "$release_workflow")
release_immutable_dev_step=$(sed -n '/name: Publish immutable dev release/,/name: Publish moving dev release/p' "$release_workflow")
release_moving_dev_step=$(sed -n '/name: Publish moving dev release/,/name: Publish tagged release/p' "$release_workflow")
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
if ! grep -Fq "'blorp-dev-release'" <<<"$release_publish_job" ||
	! grep -Fq "format('blorp-tag-release-{0}', github.ref_name)" <<<"$release_publish_job" ||
	! grep -Fq 'cancel-in-progress: false' <<<"$release_publish_job" ||
	! grep -Fq 'actions/workflows/ci.yml/runs?branch=main&event=push&status=success&per_page=1' <<<"$release_dev_ci_step" ||
	! grep -Fq 'echo "run_id=$run_id"' <<<"$release_dev_ci_step" ||
	! grep -Fq 'echo "source_sha=$source_sha"' <<<"$release_dev_ci_step" ||
	! grep -Fq 'ref: ${{ steps.dev-ci.outputs.source_sha || github.ref }}' <<<"$release_publish_job" ||
	! grep -Fq 'run-id: ${{ steps.dev-ci.outputs.run_id }}' <<<"$release_publish_job"
then
	echo "FAIL: queued dev publishers must resolve the latest successful tested toolchain" >&2
	exit 1
fi
for compiler_build_step in "$ci_build_step" "$release_compiler_build_step"; do
	if ! grep -Fq 'BLORP_CLI_C_OPTIMIZATION: -Og' <<<"$compiler_build_step"; then
		echo "FAIL: release-candidate compiler builds must use -Og" >&2
		exit 1
	fi
	if ! grep -Fq 'if [ "$RUNNER_OS" = "Linux" ]; then' <<<"$compiler_build_step" ||
		! grep -Fq 'make -j2 install' <<<"$compiler_build_step" ||
		! grep -Fq 'make install' <<<"$compiler_build_step"
	then
		echo "FAIL: Linux compiler builds must use two Make jobs with a serial fallback" >&2
		exit 1
	fi
done
if ! grep -Fq 'name: Smoke packaged compiler' "$release_workflow" ||
	! grep -Fq 'blorp/src/main.brp' "$release_workflow" ||
	! grep -Fq '"$isolated_compiler_dir/blorp" compile' "$release_workflow" ||
	grep -Fq -- '-o "$package_root/empty_main.c"' <<<"$release_build_job" ||
	! grep -Fq '"$isolated_compiler_dir/blorp" purify --dry-run' "$release_workflow" ||
	! grep -Fq '"$isolated_compiler_dir/blorp" test' "$release_workflow" ||
	! grep -Fq 'path: dist/blorp-${{ steps.meta.outputs.target }}' "$release_workflow" ||
	! grep -Fq 'name: Download tested CI binaries' "$release_workflow" ||
	! grep -Fq 'run-id: ${{ steps.dev-ci.outputs.run_id }}' "$release_workflow" ||
	! grep -Fq 'pattern: blorp-*' "$release_workflow" ||
	! grep -Fq 'merge-multiple: true' "$release_workflow" ||
	! grep -Fq 'name: Validate release assets' "$release_workflow" ||
	! grep -Fq 'assets=(dist/blorp-*)' <<<"$release_publish_job" ||
	! grep -Fq 'binary="dist/blorp-${target}"' <<<"$release_publish_job" ||
	! grep -Fq 'x86_64-unknown-linux-gnu' <<<"$release_publish_job" ||
	! grep -Fq 'aarch64-unknown-linux-gnu' <<<"$release_publish_job" ||
	! grep -Fq 'aarch64-apple-darwin' <<<"$release_publish_job"
then
	echo "FAIL: release CI must consume and qualify one direct compiler binary per target" >&2
	exit 1
fi
for public_release_path in \
	scripts/package-release \
	.github/workflows/release.yml
do
	if grep -Eq 'tar[.]gz|[.]sha256' "$public_release_path"; then
		echo "FAIL: $public_release_path must publish and consume direct binaries" >&2
		exit 1
	fi
done
if ! grep -Fq 'git fetch --quiet --no-tags origin main' <<<"$release_dev_source_step" ||
	! grep -Fq 'git diff --quiet "$source_sha" "$current_main_sha" -- .github/workflows' <<<"$release_dev_source_step" ||
	! grep -Fq 'echo "publish=false" >> "$GITHUB_OUTPUT"' <<<"$release_dev_source_step" ||
	! grep -Fq "steps.dev-source.outputs.publish == 'true'" <<<"$release_immutable_dev_step" ||
	! grep -Fq "steps.dev-source.outputs.publish == 'true'" <<<"$release_moving_dev_step"
then
	echo "FAIL: superseded main CI runs must not publish dev release tags" >&2
	exit 1
fi
for dev_release_step in "$release_immutable_dev_step" "$release_moving_dev_step"; do
	if ! grep -Fq 'workflow_files_match_main()' <<<"$dev_release_step" ||
		! grep -Fq 'git diff --quiet "$source_sha" "$current_main_sha" -- .github/workflows' <<<"$dev_release_step" ||
		! grep -Fq 'if ! push_output=$(git push' <<<"$dev_release_step"
	then
		echo "FAIL: dev tag pushes must recheck main and handle a concurrent superseding push" >&2
		exit 1
	fi
done
moving_push_line=$(grep -nF 'if ! push_output=$(git push -f origin dev' <<<"$release_moving_dev_step" | cut -d: -f1 || true)
moving_delete_line=$(grep -nF 'gh release delete dev --yes' <<<"$release_moving_dev_step" | cut -d: -f1 || true)
if [ -z "$moving_push_line" ] ||
	[ -z "$moving_delete_line" ] ||
	[ "$moving_push_line" -ge "$moving_delete_line" ] ||
	grep -Fq -- '--cleanup-tag' <<<"$release_moving_dev_step"
then
	echo "FAIL: moving dev must preserve the previous release until its tag moves" >&2
	exit 1
fi
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

for workflow in .github/workflows/ci-platform.yml .github/workflows/release.yml; do
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
