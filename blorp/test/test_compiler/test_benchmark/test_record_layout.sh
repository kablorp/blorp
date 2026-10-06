#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
runner="$repo_root/benchmarks/compiler_record_layout"
enum_layout_runner="$repo_root/benchmarks/compiler_enum_field_layout"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-record-layout-test.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT

fake_compiler="$stage_dir/fake_compiler"
fake_source="$stage_dir/fake_source.brp"
fake_support_header="$stage_dir/fake_support_header.h"
fake_support_source="$stage_dir/fake_support_source.c"
missing_expectation_source="$stage_dir/missing_expectation.brp"
unparsable_enum_record="$stage_dir/unparsable_enum_record.c"

cat > "$fake_compiler" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "run" ]; then
	# The production driver must supply the authoritative final Core input.
	for final_core in "$@"; do :; done
	if [ ! -s "$final_core" ]; then
		echo "fake compiler: missing final Core dump" >&2
		exit 1
	fi
	rows=$(cat <<'ROWS'
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutThreeFlags c_type=ProbeThreeFlags field_first=mapped_first field_second=mapped_second field_third=mapped_third
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutMixed c_type=ProbeMixed field_first=mapped_first field_count=mapped_count field_second=mapped_second field_total=mapped_total
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutHeapFlags c_type=ProbeHeapFlags field_first=mapped_first field_second=mapped_second field_third=mapped_third field_payload=mapped_payload
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutHeapDenseFlags c_type=ProbeHeapDenseFlags field_first=mapped_first field_second=mapped_second field_third=mapped_third field_fourth=mapped_fourth field_fifth=mapped_fifth field_sixth=mapped_sixth field_seventh=mapped_seventh field_eighth=mapped_eighth field_ninth=mapped_ninth field_payload=mapped_payload
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutHeapInterleavedFlags c_type=ProbeHeapInterleavedFlags field_first=mapped_first field_count=mapped_count field_second=mapped_second
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutHeapStates c_type=ProbeHeapStates field_count=mapped_count field_first=mapped_first field_second=mapped_second field_third=mapped_third
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutForeignHeapFlags c_type=ProbeForeignHeapFlags field_first=mapped_first field_second=mapped_second field_count=mapped_count
RECORD_LAYOUT_SYMBOL schema=1 record=LayoutForeignHeapState c_type=ProbeForeignHeapState field_state=mapped_state field_count=mapped_count
ROWS
	)
	case "${BLORP_RECORD_LAYOUT_FAKE_MAPPING:-valid}" in
		valid) printf '%s\n' "$rows" ;;
		missing) printf '%s\n' "$rows" | sed '1d' ;;
		duplicate) printf '%s\n%s\n' "$rows" "$rows" ;;
		malformed) printf '%s\n' "$rows" | sed 's/c_type=ProbeMixed/c_type=bad-name/' ;;
		duplicate_key) printf '%s\n' "$rows" | sed 's/schema=1/schema=1 schema=1/' ;;
		unknown_field) printf '%s\n' "$rows" | sed 's/field_total=mapped_total/field_extra=mapped_total/' ;;
	esac
	exit 0
fi

output=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			output="$2"
			shift 2
			;;
		--dump-core-file=*)
			printf '%s\n' '-- blorp mock' '===== after final =====' '{}' > "${1#*=}"
			shift
			;;
		*)
			shift
			;;
	esac
done

if [ -z "$output" ]; then
	echo "fake compiler: missing -o" >&2
	exit 1
fi

cat > "$output" <<'C'
#include <stddef.h>
#include <stdint.h>

/* The managed header matches runtime_decl.c, not an assumed byte array. */
typedef struct blorp_Object_s {
	_Atomic long refcount;
	uint32_t alloc_class;
	uint32_t destructor_id;
} blorp_Object;

typedef struct ProbeThreeFlags {
	blorp_Object header;
	_Bool mapped_first : 1;
	_Bool mapped_second : 1;
	_Bool mapped_third : 1;
} ProbeThreeFlags;
typedef struct {
	blorp_Object header;
	long mapped_count;
	long mapped_total;
	_Bool mapped_first;
	_Bool mapped_second;
} ProbeMixed;
typedef struct ProbeHeapFlags {
	blorp_Object header;
	void* mapped_payload;
	_Bool mapped_first : 1;
	_Bool mapped_second : 1;
	_Bool mapped_third : 1;
} ProbeHeapFlags;
typedef struct ProbeHeapDenseFlags {
	blorp_Object header;
	void* mapped_payload;
	_Bool mapped_first : 1;
	_Bool mapped_second : 1;
	_Bool mapped_third : 1;
	_Bool mapped_fourth : 1;
	_Bool mapped_fifth : 1;
	_Bool mapped_sixth : 1;
	_Bool mapped_seventh : 1;
	_Bool mapped_eighth : 1;
	_Bool mapped_ninth : 1;
} ProbeHeapDenseFlags;
typedef struct ProbeHeapInterleavedFlags {
	blorp_Object header;
	long mapped_count;
	_Bool mapped_first;
	_Bool mapped_second;
} ProbeHeapInterleavedFlags;
typedef struct ProbeHeapStates {
	blorp_Object header;
	long mapped_count;
	uint8_t mapped_first;
	uint8_t mapped_second;
	uint8_t mapped_third;
} ProbeHeapStates;
typedef struct ProbeForeignHeapFlags {
	blorp_Object header;
	int mapped_first;
	int mapped_second;
	long mapped_count;
} ProbeForeignHeapFlags;
typedef struct ProbeForeignHeapState {
	blorp_Object header;
	long mapped_state;
	long mapped_count;
} ProbeForeignHeapState;

int main(void) {
	return 0;
}
C
EOF
chmod +x "$fake_compiler"
printf '%s\n' \
	'-- EXPECT-C: typedef struct ProbeThreeFlags {' \
	> "$fake_source"
printf '%s\n' 'int blorp_layout_foreign_mixed_fields(int first, long count, int second, long total);' > "$fake_support_header"
printf '%s\n' 'int fake_support_source;' > "$fake_support_source"
printf '%s\n' \
	'-- EXPECT-C: typedef struct MissingLayoutExpectation {' \
	> "$missing_expectation_source"
cat > "$unparsable_enum_record" <<'C'
typedef struct blorp_src_compiler_stage_02_lex_token__Trivia {
	unsigned char other;
} blorp_src_compiler_stage_02_lex_token__Trivia;
C

output=$(
	BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
	BLORP_RECORD_LAYOUT_COMPILER="$fake_compiler" \
	BLORP_RECORD_LAYOUT_SOURCE="$fake_source" \
	BLORP_RECORD_LAYOUT_SUPPORT_HEADER="$fake_support_header" \
	BLORP_RECORD_LAYOUT_SUPPORT_SOURCE="$fake_support_source" \
	BLORP_RECORD_LAYOUT_CC="${CC:-cc} -pipe" \
	"$runner"
)

if [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -ne 17 ]; then
	echo "FAIL: record layout probe must emit one metadata and sixteen layout rows" >&2
	printf '%s\n' "$output" >&2
	exit 1
fi

for mode in O0 O2; do
	for expected in \
		"layout=three_flags size=24 align=8 allocator_bytes=24 header_offset=0 header_size=16 c_type=ProbeThreeFlags" \
		"layout=mixed size=40 align=8 allocator_bytes=40 header_offset=0 header_size=16 count_offset=16 count_size=8 total_offset=24 total_size=8 first_offset=32 first_size=1 second_offset=33 second_size=1 c_type=ProbeMixed" \
		"layout=heap_flags size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 payload_offset=16 payload_size=8 c_type=ProbeHeapFlags" \
		"layout=dense_heap_flags size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 payload_offset=16 payload_size=8 c_type=ProbeHeapDenseFlags" \
		"layout=interleaved_heap_flags size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 count_offset=16 count_size=8 first_offset=24 first_size=1 second_offset=25 second_size=1 c_type=ProbeHeapInterleavedFlags" \
		"layout=heap_states size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 count_offset=16 count_size=8 first_offset=24 first_size=1 second_offset=25 second_size=1 third_offset=26 third_size=1 c_type=ProbeHeapStates" \
		"layout=foreign_heap_flags size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 first_offset=16 first_size=4 second_offset=20 second_size=4 count_offset=24 count_size=8 c_type=ProbeForeignHeapFlags" \
		"layout=foreign_heap_state size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 state_offset=16 state_size=8 count_offset=24 count_size=8 c_type=ProbeForeignHeapState"
	do
		if ! grep -Fq "RECORD_LAYOUT mode=$mode $expected" <<<"$output"; then
			echo "FAIL: missing $mode layout row: $expected" >&2
			printf '%s\n' "$output" >&2
			exit 1
		fi
	done
done

if ! grep -Eq '^RECORD_LAYOUT_META schema=3 platform=[^ ]+ git_revision=[0-9a-f]{40} git_state=(clean|dirty) source_sha256=[0-9a-f]{64} support_header_sha256=[0-9a-f]{64} support_source_sha256=[0-9a-f]{64} compiler_sha256=[0-9a-f]{64} cc_command_sha256=[0-9a-f]{64} cc_version_sha256=[0-9a-f]{64} cc_target=[^ ]+ generated_c_sha256=[0-9a-f]{64}$' <<<"$output"; then
	echo "FAIL: record layout probe metadata is incomplete" >&2
	printf '%s\n' "$output" >&2
	exit 1
fi

if BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
	BLORP_RECORD_LAYOUT_COMPILER="$fake_compiler" \
	BLORP_RECORD_LAYOUT_SOURCE="$missing_expectation_source" \
	BLORP_RECORD_LAYOUT_SUPPORT_HEADER="$fake_support_header" \
	BLORP_RECORD_LAYOUT_SUPPORT_SOURCE="$fake_support_source" \
	BLORP_RECORD_LAYOUT_CC="${CC:-cc} -pipe" \
	"$runner" >"$stage_dir/missing.out" 2>"$stage_dir/missing.err"
then
	echo "FAIL: record layout probe must reject missing generated C expectations" >&2
	exit 1
fi

if ! grep -Fq \
	'missing generated C expectation: typedef struct MissingLayoutExpectation {' \
	"$stage_dir/missing.err"
then
	echo "FAIL: record layout probe expectation error is incomplete" >&2
	cat "$stage_dir/missing.err" >&2
	exit 1
fi

for corruption in missing duplicate malformed duplicate_key unknown_field; do
	if BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
		BLORP_RECORD_LAYOUT_COMPILER="$fake_compiler" \
		BLORP_RECORD_LAYOUT_SOURCE="$fake_source" \
		BLORP_RECORD_LAYOUT_SUPPORT_HEADER="$fake_support_header" \
		BLORP_RECORD_LAYOUT_SUPPORT_SOURCE="$fake_support_source" \
		BLORP_RECORD_LAYOUT_FAKE_MAPPING="$corruption" \
		"$runner" >"$stage_dir/$corruption.out" 2>"$stage_dir/$corruption.err"
	then
		echo "FAIL: record layout probe must reject $corruption symbol mappings" >&2
		exit 1
	fi
	if ! grep -Fq 'compiler_record_layout: invalid symbol mapping:' "$stage_dir/$corruption.err"; then
		echo "FAIL: $corruption mapping rejection lacks a diagnostic" >&2
		cat "$stage_dir/$corruption.err" >&2
		exit 1
	fi
done

if "$enum_layout_runner" \
	--generated-c "$unparsable_enum_record" \
	>"$stage_dir/unparsable-enum.out" \
	2>"$stage_dir/unparsable-enum.err"
then
	echo "FAIL: enum layout probe must reject a present record with a missing field" >&2
	exit 1
fi

if ! grep -Fq \
	'generated record blorp_src_compiler_stage_02_lex_token__Trivia is missing field kind' \
	"$stage_dir/unparsable-enum.err"
then
	echo "FAIL: enum layout probe missing-field error is incomplete" >&2
	cat "$stage_dir/unparsable-enum.err" >&2
	exit 1
fi

if ! "$runner" --help | grep -Fq 'Usage: benchmarks/compiler_record_layout'; then
	echo "FAIL: record layout probe help is missing" >&2
	exit 1
fi

if "$runner" unexpected >"$stage_dir/unexpected.out" 2>"$stage_dir/unexpected.err"; then
	echo "FAIL: record layout probe must reject unexpected arguments" >&2
	exit 1
fi

if ! grep -Fq 'unexpected argument: unexpected' "$stage_dir/unexpected.err"; then
	echo "FAIL: record layout probe argument error is incomplete" >&2
	exit 1
fi

echo "compiler record layout benchmark contract: ok"
