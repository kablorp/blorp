#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/../../.."

generator_source=blorp/tool/generate_build_sources.brp
generator=blorp/build/_build/build-tools/generate-build-sources

if [ ! -f "$generator_source" ]; then
	echo "FAIL: build-source generation must be implemented in Blorp" >&2
	exit 1
fi

make compiler-build-source-generator >/dev/null

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-build-source-generator.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$generator" embedded-std standard_library/src >"$tmp_dir/embedded_std.brp"
cmp blorp/src/compiler/stage_01_file_io/embedded_std.brp "$tmp_dir/embedded_std.brp"
module_names=$(sed -n '/pure func embedded_std_module_names()/,/^$/p' "$tmp_dir/embedded_std.brp")
if ! grep -Fq '"test"' <<<"$module_names"; then
	echo "FAIL: embedded std must include the production test module" >&2
	exit 1
fi
if grep -Fq '"std/' <<<"$module_names"; then
	echo "FAIL: embedded standard-library module names must not retain the std/ namespace" >&2
	exit 1
fi
if grep -Fq '"test/' <<<"$module_names"; then
	echo "FAIL: embedded std must not include standard-library test modules" >&2
	exit 1
fi
if grep -Fq '"compiler_runtime"' <<<"$module_names"; then
	echo "FAIL: embedded std still exposes the compiler runtime provider" >&2
	exit 1
fi

BLORP_BUILD_VERSION=1.2.3-test \
BLORP_BUILD_COMMIT=0123456789abcdef \
BLORP_BUILD_TARGET=test-target \
BLORP_BUILD_CHANNEL=test-channel \
BLORP_BUILD_DIRTY=false \
	"$generator" build-info blorp/build/VERSION >"$tmp_dir/build_info.brp"
for expected_build_info in \
	'VERSION: String = "1.2.3-test"' \
	'VERSION_DESCRIPTION: String = "blorp 1.2.3-test\ncommit: 0123456789abcdef\ntarget: test-target\nchannel: test-channel\ndirty: false\nstd: embedded, hash " + embedded_std_digest'
do
	grep -Fq "$expected_build_info" "$tmp_dir/build_info.brp"
done

utf8_commit=$(printf 'quote" slash\\ ${oops} caf\303\251')
BLORP_BUILD_COMMIT="$utf8_commit" \
	"$generator" build-info blorp/build/VERSION >"$tmp_dir/escaped_build_info.brp"
cat >"$tmp_dir/embedded_std.brp" <<'BRP'
embedded_std_digest: String = "test-digest"
BRP
bootstrap=$(scripts/blorp-compiler-bootstrap --print-path)
"$bootstrap" check --no-format "$tmp_dir/escaped_build_info.brp" >/dev/null

printf 'one\ntwo\n' >"$tmp_dir/invalid-version"
if "$generator" build-info "$tmp_dir/invalid-version" \
	>"$tmp_dir/invalid-version.out" 2>"$tmp_dir/invalid-version.err"
then
	echo "FAIL: build-info accepted a multi-line version source" >&2
	exit 1
fi
grep -Fq 'version file must contain exactly one non-empty line' \
	"$tmp_dir/invalid-version.err"

if "$generator" unknown-mode >"$tmp_dir/usage.out" 2>"$tmp_dir/usage.err"; then
	echo "FAIL: build-source generator accepted an unknown mode" >&2
	exit 1
fi
grep -Fq 'usage: generate-build-sources' "$tmp_dir/usage.err"

"$generator" embedded-runtime-c \
	blorp/src/lib/runtime/native/minicoro.h \
	blorp/src/lib/runtime/native/runtime.c \
	blorp/src/lib/runtime/native/runtime_decl.c \
	>"$tmp_dir/provider.c"

cat >"$tmp_dir/dump.c" <<'C'
#include <stddef.h>
#include <stdio.h>
#include <string.h>

extern const char blorp_compiler_runtime_source_data[];
extern const size_t blorp_compiler_runtime_source_data_len;
extern const char blorp_compiler_runtime_decl_data[];
extern const size_t blorp_compiler_runtime_decl_data_len;

int main(int argc, char** argv) {
    const char* data = NULL;
    size_t length = 0;
    if (argc == 2 && strcmp(argv[1], "runtime") == 0) {
        data = blorp_compiler_runtime_source_data;
        length = blorp_compiler_runtime_source_data_len;
    } else if (argc == 2 && strcmp(argv[1], "declarations") == 0) {
        data = blorp_compiler_runtime_decl_data;
        length = blorp_compiler_runtime_decl_data_len;
    } else {
        return 2;
    }
    return fwrite(data, 1, length, stdout) == length ? 0 : 1;
}
C

cc -std=c11 "$tmp_dir/provider.c" "$tmp_dir/dump.c" -o "$tmp_dir/dump"

{
	printf '#define _GNU_SOURCE\n#define MINICORO_IMPL\n'
	cat blorp/src/lib/runtime/native/minicoro.h
	printf '\n'
	cat blorp/src/lib/runtime/native/runtime.c
} >"$tmp_dir/expected-runtime.c"

{
	printf '#define _GNU_SOURCE\n'
	cat blorp/src/lib/runtime/native/minicoro.h
	printf '\n'
	cat blorp/src/lib/runtime/native/runtime_decl.c
} >"$tmp_dir/expected-declarations.c"

"$tmp_dir/dump" runtime >"$tmp_dir/actual-runtime.c"
"$tmp_dir/dump" declarations >"$tmp_dir/actual-declarations.c"

cmp "$tmp_dir/expected-runtime.c" "$tmp_dir/actual-runtime.c"
cmp "$tmp_dir/expected-declarations.c" "$tmp_dir/actual-declarations.c"

echo "PASS: Blorp build-source generation is byte-exact"
