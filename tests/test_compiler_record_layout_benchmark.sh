#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runner="$repo_root/benchmarks/compiler_record_layout"
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-record-layout-test.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT

fake_host="$stage_dir/fake_host"
fake_source="$stage_dir/fake_source.brp"
fake_support_header="$stage_dir/fake_support_header.h"
fake_support_source="$stage_dir/fake_support_source.c"
missing_expectation_source="$stage_dir/missing_expectation.brp"

cat > "$fake_host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			output="$2"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

if [ -z "$output" ]; then
	echo "fake host: missing -o" >&2
	exit 1
fi

cat > "$output" <<'C'
#include <stddef.h>
#include <stdint.h>

static const size_t blorp_pool_sizes[] = {32, 64, 96, 128};
static int blorp_pool_class(size_t size) {
	if (size == 0 || size > 128) return -1;
	return (int)((size - 1) / 32);
}

typedef struct { int first; int second; int third; } LayoutThreeFlags;
typedef struct {
	int tag;
	LayoutThreeFlags value;
} blorp_StackOption_LayoutThreeFlags;
typedef struct {
	int first;
	long count;
	int second;
	long total;
} LayoutMixed;
typedef struct LayoutHeapFlags {
	long header[2];
	_Bool first;
	_Bool second;
	_Bool third;
	void* payload;
} LayoutHeapFlags;
typedef struct {
	int first;
	long count;
	int second;
	long total;
} LayoutForeignMixed;

int main(void) {
	return 0;
}
C
EOF
chmod +x "$fake_host"
printf '%s\n' \
	'-- EXPECT-C: typedef struct { int first; int second; int third; } LayoutThreeFlags;' \
	> "$fake_source"
printf '%s\n' '#define blorp_layout_foreign_identity(value) (value)' > "$fake_support_header"
printf '%s\n' 'int fake_support_source;' > "$fake_support_source"
printf '%s\n' \
	'-- EXPECT-C: typedef struct MissingLayoutExpectation {' \
	> "$missing_expectation_source"

output=$(
	BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
	BLORP_RECORD_LAYOUT_HOST="$fake_host" \
	BLORP_RECORD_LAYOUT_SOURCE="$fake_source" \
	BLORP_RECORD_LAYOUT_SUPPORT_HEADER="$fake_support_header" \
	BLORP_RECORD_LAYOUT_SUPPORT_SOURCE="$fake_support_source" \
	BLORP_RECORD_LAYOUT_CC="${CC:-cc} -pipe" \
	BLORP_COMPILER_BRIDGE_BIN="$fake_host" \
	"$runner"
)

if [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -ne 9 ]; then
	echo "FAIL: record layout probe must emit one metadata and eight layout rows" >&2
	printf '%s\n' "$output" >&2
	exit 1
fi

for mode in O0 O2; do
	for expected in \
		"layout=three_flags size=12 align=4 c_type=LayoutThreeFlags" \
		"layout=mixed size=32 align=8 c_type=LayoutMixed" \
		"layout=heap_flags size=32 align=8 allocator_bytes=32 header_offset=0 header_size=16 first_offset=16 first_size=1 second_offset=17 second_size=1 third_offset=18 third_size=1 payload_offset=24 payload_size=8 c_type=LayoutHeapFlags" \
		"layout=foreign_mixed size=32 align=8 first_offset=0 first_size=4 count_offset=8 count_size=8 second_offset=16 second_size=4 total_offset=24 total_size=8 c_type=LayoutForeignMixed"
	do
		if ! grep -Fq "RECORD_LAYOUT mode=$mode $expected" <<<"$output"; then
			echo "FAIL: missing $mode layout row: $expected" >&2
			printf '%s\n' "$output" >&2
			exit 1
		fi
	done
done

if ! grep -Eq '^RECORD_LAYOUT_META schema=1 platform=[^ ]+ git_revision=[0-9a-f]{40} git_state=(clean|dirty) source_sha256=[0-9a-f]{64} support_header_sha256=[0-9a-f]{64} support_source_sha256=[0-9a-f]{64} host_sha256=[0-9a-f]{64} bridge_compiler_sha256=[0-9a-f]{64} cc_command_sha256=[0-9a-f]{64} cc_version_sha256=[0-9a-f]{64} cc_target=[^ ]+ generated_c_sha256=[0-9a-f]{64}$' <<<"$output"; then
	echo "FAIL: record layout probe metadata is incomplete" >&2
	printf '%s\n' "$output" >&2
	exit 1
fi

if BLORP_RECORD_LAYOUT_SKIP_BUILD=1 \
	BLORP_RECORD_LAYOUT_HOST="$fake_host" \
	BLORP_RECORD_LAYOUT_SOURCE="$missing_expectation_source" \
	BLORP_RECORD_LAYOUT_SUPPORT_HEADER="$fake_support_header" \
	BLORP_RECORD_LAYOUT_SUPPORT_SOURCE="$fake_support_source" \
	BLORP_RECORD_LAYOUT_CC="${CC:-cc} -pipe" \
	BLORP_COMPILER_BRIDGE_BIN="$fake_host" \
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
