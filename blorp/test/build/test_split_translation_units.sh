#!/usr/bin/env bash
# Compile a nontrivial program as a split C artifact and require that the
# published file set compiles, links, and runs exactly like the single-file
# build of the same program.

set -u

cd "$(dirname "$0")/../../.."

compiler="${BLORP_BIN:-bin/blorp}"
source_program="blorp/tool/generate_build_sources.brp"
native_runtime="blorp/src/lsp/server/native_runtime.c"
runtime_sources="blorp/build/_build/blorp-cli/runtime_sources.c"
# The build cache directory can accumulate runtime-<hash>.o objects from
# earlier runtime.c/minicoro.h/cc revisions across many `make` invocations, so
# picking any file that matches runtime-*.o is not safe. Ask the Makefile for
# the one it would use for the current sources instead of guessing from the
# directory listing.
runtime_object_name=$(make -n build-blorp-cli 2>/dev/null | grep -o 'runtime-[0-9a-f]\{64\}\.o' | head -n 1)
runtime_object="blorp/build/_build/blorp-cli/${runtime_object_name}"

if [ ! -x "$compiler" ]; then
    echo "FAIL: $compiler is not built; run make first" >&2
    exit 1
fi
if [ ! -f "$runtime_sources" ] || [ -z "$runtime_object_name" ] || [ ! -f "$runtime_object" ]; then
    echo "FAIL: prepared CLI runtime inputs are missing; run make first" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp_split_units.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT

log="$work_dir/build.log"
split_dir="$work_dir/split"
single_dir="$work_dir/single"
mkdir -p "$split_dir" "$single_dir"

cc_include_flags=(
    -Iblorp/src/compiler/stage_01_generated_inputs
    -Iblorp/src/compiler/stage_04_modules
    -Iblorp/src/compiler/stage_06_typecheck/graph
    -Iblorp/src/compiler/stage_06_typecheck/type_system
    -Iblorp/src
    -Iblorp/src/lib
    -Iblorp/src/lsp/server
    -Iblorp/src/test
)
cc_common_flags=(
    -fwrapv
    -pipe
    -w
    -DBLORP_COMPILER_RUNTIME_SOURCES=1
    -include
    blorp/src/lib/runtime/native/runtime_decl.c
)

fail() {
    echo "FAIL: $1" >&2
    [ -f "$log" ] && cat "$log" >&2
    exit 1
}

# --- split emission -------------------------------------------------------

if ! "$compiler" compile --no-format --no-embed-runtime \
    --c-translation-units=4 -o "$split_dir/x.c" "$source_program" \
    > "$log" 2>&1; then
    fail "blorp compile --c-translation-units=4 should succeed"
fi

if ! grep -qF "(4 translation units)" "$log"; then
    fail "split compile should report how many translation units it wrote"
fi

for expected in x.h x.0.c x.1.c x.2.c x.3.c x.units; do
    if [ ! -f "$split_dir/$expected" ]; then
        fail "split compile should write $expected"
    fi
done

if [ -f "$split_dir/x.c" ]; then
    fail "split compile should not write the single-file artifact"
fi

expected_manifest="$work_dir/expected-manifest.txt"
{
    echo "$split_dir/x.h"
    echo "$split_dir/x.0.c"
    echo "$split_dir/x.1.c"
    echo "$split_dir/x.2.c"
    echo "$split_dir/x.3.c"
} > "$expected_manifest"

if ! diff -u "$expected_manifest" "$split_dir/x.units" > "$work_dir/manifest.diff" 2>&1; then
    cat "$work_dir/manifest.diff" >&2
    fail "the manifest should list the shared header and every body, in order"
fi

for unit in 0 1 2 3; do
    if ! head -n 1 "$split_dir/x.$unit.c" | grep -qF '#include "x.h"'; then
        fail "translation unit $unit should include the shared header by name"
    fi
done

echo "PASS: blorp compile --c-translation-units publishes a manifest-listed file set"

# --- every unit is a valid translation unit on its own --------------------

for unit in 0 1 2 3; do
    if ! "${BLORP_CC:-clang}" -fsyntax-only "${cc_common_flags[@]}" "${cc_include_flags[@]}" \
        "$split_dir/x.$unit.c" > "$log" 2>&1; then
        fail "translation unit $unit should compile on its own"
    fi
done

echo "PASS: each emitted translation unit compiles independently"

# --- the split set links and runs like the single-file build --------------

split_bin="$work_dir/split.bin"
if ! "${BLORP_CC:-clang}" -O0 "${cc_common_flags[@]}" "${cc_include_flags[@]}" \
    "$split_dir/x.0.c" "$split_dir/x.1.c" "$split_dir/x.2.c" "$split_dir/x.3.c" \
    "$runtime_object" "$runtime_sources" "$native_runtime" \
    -lm -lpthread -o "$split_bin" > "$log" 2>&1; then
    fail "the split translation units should link into one program"
fi

single_c="$single_dir/x.c"
if ! "$compiler" compile --no-format --no-embed-runtime -o "$single_c" "$source_program" \
    > "$log" 2>&1; then
    fail "the single-file build of the same program should succeed"
fi

single_bin="$work_dir/single.bin"
if ! "${BLORP_CC:-clang}" -O0 "${cc_common_flags[@]}" "${cc_include_flags[@]}" \
    "$single_c" "$runtime_object" "$runtime_sources" "$native_runtime" \
    -lm -lpthread -o "$single_bin" > "$log" 2>&1; then
    fail "the single-file build should link"
fi

"$split_bin" build-info blorp/build/VERSION > "$work_dir/split.out" 2>"$work_dir/split.err"
split_status=$?
"$single_bin" build-info blorp/build/VERSION > "$work_dir/single.out" 2>"$work_dir/single.err"
single_status=$?

if [ "$split_status" -ne "$single_status" ]; then
    cat "$work_dir/split.err" >&2
    fail "the split program should exit like the single-file program"
fi
if ! cmp -s "$work_dir/split.out" "$work_dir/single.out"; then
    diff -u "$work_dir/single.out" "$work_dir/split.out" >&2
    fail "the split program should print what the single-file program prints"
fi

echo "PASS: the split program behaves like the single-file program"

# --- rejected combinations ------------------------------------------------

if "$compiler" compile --no-format --c-translation-units=4 \
    -o "$work_dir/embedded.c" "$source_program" > "$log" 2>&1; then
    fail "--c-translation-units above 1 should require --no-embed-runtime"
fi
if ! grep -qF -- "--no-embed-runtime" "$log"; then
    fail "the embedded-runtime rejection should point at --no-embed-runtime"
fi

if "$compiler" compile --no-format --no-embed-runtime --c-translation-units=0 \
    -o "$work_dir/zero.c" "$source_program" > "$log" 2>&1; then
    fail "--c-translation-units=0 should be rejected"
fi

echo "PASS: invalid --c-translation-units requests are rejected"

# --- one unit keeps the single-file contract ------------------------------

one_dir="$work_dir/one"
mkdir -p "$one_dir"
if ! "$compiler" compile --no-format --no-embed-runtime --c-translation-units=1 \
    -o "$one_dir/x.c" "$source_program" > "$log" 2>&1; then
    fail "--c-translation-units=1 should succeed"
fi

if [ ! -f "$one_dir/x.c" ] || [ -f "$one_dir/x.h" ] || [ -f "$one_dir/x.units" ]; then
    fail "--c-translation-units=1 should write exactly one C file"
fi
if ! cmp -s "$one_dir/x.c" "$single_c"; then
    fail "--c-translation-units=1 should match the default single-file output"
fi

echo "PASS: --c-translation-units=1 keeps the single-file output"
echo "BLORP_GATE_RESULT gate=build_split_translation_units status=PASS passed=5 failed=0 tests=5"
