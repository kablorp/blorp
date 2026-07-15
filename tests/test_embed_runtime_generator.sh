#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-runtime-embed.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

ocaml compiler/tools/gen_embed_runtime_c.ml \
	compiler/lib/minicoro.h \
	compiler/lib/runtime.c \
	compiler/lib/runtime_decl.c \
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
	cat compiler/lib/minicoro.h
	printf '\n'
	cat compiler/lib/runtime.c
} >"$tmp_dir/expected-runtime.c"

{
	printf '#define _GNU_SOURCE\n'
	cat compiler/lib/minicoro.h
	printf '\n'
	cat compiler/lib/runtime_decl.c
} >"$tmp_dir/expected-declarations.c"

"$tmp_dir/dump" runtime >"$tmp_dir/actual-runtime.c"
"$tmp_dir/dump" declarations >"$tmp_dir/actual-declarations.c"

cmp "$tmp_dir/expected-runtime.c" "$tmp_dir/actual-runtime.c"
cmp "$tmp_dir/expected-declarations.c" "$tmp_dir/actual-declarations.c"

echo "PASS: compiler runtime source embedding is byte-exact"
