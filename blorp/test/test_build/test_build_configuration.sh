#!/usr/bin/env bash
# Behavioural checks of the build graph: they run the built compiler, the
# generator and `make -n` under different settings.
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

echo "PASS: build configuration behaves as expected"
