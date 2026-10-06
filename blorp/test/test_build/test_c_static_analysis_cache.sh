#!/usr/bin/env bash
# scripts/c-static-analysis must skip the analysis when its inputs are
# unchanged since a passing run, rerun when an input or a header it includes
# changes, and never record a stamp for a failing run. Runs the real script on
# copies of its inputs with a `clang` wrapper that does the real dependency
# scan (clang -M) but only counts `--analyze` runs, so it takes seconds.
set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/blorp_c_static_analysis_cache.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

REAL_CLANG=$(command -v clang) || { echo "SKIP: clang is not installed"; exit 0; }
mkdir -p "$SCRATCH/bin" "$SCRATCH/work/blorp/src/lib/runtime" "$SCRATCH/work/blorp/src/lsp"
cp -R "$ROOT/blorp/src/lib/runtime/native" "$SCRATCH/work/blorp/src/lib/runtime/native"
cp -R "$ROOT/blorp/src/lsp/server" "$SCRATCH/work/blorp/src/lsp/server"
cat > "$SCRATCH/bin/clang" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
	if [ "\$arg" = "--analyze" ]; then
		echo analyzed >> "$SCRATCH/analyze_runs"
		[ -z "\${FAKE_ANALYSIS_FAILS:-}" ] || exit 1
		exit 0
	fi
done
exec "$REAL_CLANG" "\$@"
SH
chmod +x "$SCRATCH/bin/clang"

failures=0
export BLORP_QUALITY_CACHE_DIR="$SCRATCH/cache"

# Runs the script in the scratch tree; sets `output`.
run_analysis() {
	output=$(cd "$SCRATCH/work" && PATH="$SCRATCH/bin:$PATH" \
		bash "$ROOT/scripts/c-static-analysis" blorp/src/lsp/server/native_runtime.c 2>&1)
	status=$?
}

analysis_runs() {
	if [ -f "$SCRATCH/analyze_runs" ]; then wc -l < "$SCRATCH/analyze_runs" | tr -d ' '; else echo 0; fi
}

# expect NAME WANTED_RUNS_SO_FAR WANTED_OUTPUT_PATTERN
expect() {
	local name="$1" want_runs="$2" want_output="$3"
	if [ "$(analysis_runs)" != "$want_runs" ] || ! grep -q "$want_output" <<<"$output"; then
		echo "FAIL: $name (analyzer runs: $(analysis_runs), wanted $want_runs; output: $output)"
		failures=$((failures + 1))
	else
		echo "PASS: $name"
	fi
}

run_analysis
expect "the first run analyzes all three files" 3 "passed"

run_analysis
expect "an unchanged rerun is skipped" 3 "unchanged inputs (.*), skipped"

echo "/* edited */" >> "$SCRATCH/work/blorp/src/lib/runtime/native/runtime_decl.c"
run_analysis
expect "an edited source reruns the analysis" 6 "passed"

run_analysis
expect "the edited inputs are then skipped" 6 "skipped"

# Headers count too: one pulled in by #include and one forced by -include.
echo "/* edited */" >> "$SCRATCH/work/blorp/src/lsp/server/native_runtime.h"
run_analysis
expect "an edited #included header reruns the analysis" 9 "passed"

echo "/* edited */" >> "$SCRATCH/work/blorp/src/lib/runtime/native/minicoro.h"
run_analysis
expect "an edited -include header reruns the analysis" 12 "passed"

# A failing analysis stops at its first failing file and records no stamp, so
# an identical rerun analyzes (and fails) again instead of being skipped.
echo "/* failing edit */" >> "$SCRATCH/work/blorp/src/lsp/server/native_runtime.c"
FAKE_ANALYSIS_FAILS=1 run_analysis
failed_first=$status
expect "a failing analysis does not report a pass" 13 "^$"
FAKE_ANALYSIS_FAILS=1 run_analysis
failed_again=$status
expect "a failing analysis records no stamp" 14 "^$"
if [ "$failed_first" -eq 0 ] || [ "$failed_again" -eq 0 ]; then
	echo "FAIL: a failing analysis exited 0 (exits $failed_first, $failed_again)"
	failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
