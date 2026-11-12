#!/bin/bash
# blorp Benchmark Suite
#
# Layout:
#   benchmarks/blorp/<name>.brp       # the benchmark program; a benchmark needs one
#   benchmarks/c/<name>.c
#   benchmarks/go/<name>.go
#   benchmarks/ocaml/<name>.ml
#   benchmarks/python/<name>.py
#   benchmarks/args/<name>.txt        # optional shared CLI args
#
# Each language runner instruments the benchmark entry point inside the spawned
# process and reports a machine-readable BENCH line. The shell harness only
# builds/runs/collects, so reported timings exclude shell/process startup time.
#
# Usage:
#   bash benchmarks/bench.sh              # Run all benchmarks
#   bash benchmarks/bench.sh fib          # Run a single benchmark
#   bash benchmarks/bench.sh --list       # List available benchmarks
#
# Prerequisites:
#   make -C blorp compiler             # the blorp column (or set BLORP_COMPILER)
#
# Environment:
#   PYTHON=python3.11                  bash benchmarks/bench.sh   # Use specific Python
#   GO=go1.22                          bash benchmarks/bench.sh   # Use specific Go
#   OCAMLOPT=ocamlopt                  bash benchmarks/bench.sh   # Use specific OCaml native compiler
#   CC=gcc                             bash benchmarks/bench.sh   # Use specific C compiler
#   BLORP_COMPILER=/path/compiler      bash benchmarks/bench.sh fib # Select the Blorp compiler
#   BENCH_RUNS=5                       bash benchmarks/bench.sh   # Timed runs per language (default: 1)
#   BENCH_WARMUPS=1                    bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
#   BENCH_ALLOC_STATS=1                bash benchmarks/bench.sh   # Separate allocation runs for the Blorp column
#   BENCH_RESOURCE_STATS=1             bash benchmarks/bench.sh   # Retired instructions and peak RSS (macOS /usr/bin/time -l)
#   BENCH_VERBOSE=1                    bash benchmarks/bench.sh   # Print build logs on failures

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLORP_COMPILER="${BLORP_COMPILER:-$PROJECT_DIR/blorp/build/blorp}"
PYTHON="${PYTHON:-python3}"
GO="${GO:-go}"
OCAMLOPT="${OCAMLOPT:-ocamlopt}"
CC="${CC:-cc}"
BENCH_RUNS="${BENCH_RUNS:-1}"
BENCH_WARMUPS="${BENCH_WARMUPS:-0}"
BENCH_ALLOC_STATS="${BENCH_ALLOC_STATS:-0}"
BENCH_RESOURCE_STATS="${BENCH_RESOURCE_STATS:-0}"
BENCH_VERBOSE="${BENCH_VERBOSE:-0}"
BENCH_FAILED=0
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Ordered benchmark list (determines display order)
ALL_BENCHMARKS="numeric_loop fib dict_ops list_ops binary_trees compiler_ast compiler_emit"
EXTRA_BENCHMARKS="control_flow_accumulators helper_accumulators"

die() { echo "error: $1" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

python_cmd_runs() {
    "$1" -c 'import sys' >/dev/null 2>&1
}

is_known_benchmark() {
    local needle="$1"
    case " $ALL_BENCHMARKS $EXTRA_BENCHMARKS " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

bench_args_for() {
    local name="$1"
    local args_file="$SCRIPT_DIR/args/$name.txt"
    [ -f "$args_file" ] && cat "$args_file"
    return 0
}

src_for() {
    local lang="$1" name="$2"
    case "$lang" in
        blorp) printf "%s/blorp/%s.brp" "$SCRIPT_DIR" "$name" ;;
        c) printf "%s/c/%s.c" "$SCRIPT_DIR" "$name" ;;
        go) printf "%s/go/%s.go" "$SCRIPT_DIR" "$name" ;;
        ocaml) printf "%s/ocaml/%s.ml" "$SCRIPT_DIR" "$name" ;;
        python) printf "%s/python/%s.py" "$SCRIPT_DIR" "$name" ;;
        *) return 1 ;;
    esac
}

has_bench() {
    local lang="$1" name="$2"
    local src
    src="$(src_for "$lang" "$name")"
    [ -f "$src" ]
}

compiled_out_for() {
    local lang="$1" name="$2"
    printf "%s/bench_%s_%s" "$TEMP_DIR" "$lang" "$name"
}

build_log_for() {
    local lang="$1" name="$2"
    printf "%s/build_%s_%s.log" "$TEMP_DIR" "$lang" "$name"
}

build_status_for() {
    local lang="$1" name="$2"
    printf "%s/build_%s_%s.status" "$TEMP_DIR" "$lang" "$name"
}

mark_build_status() {
    local lang="$1" name="$2" status="$3"
    printf "%s\n" "$status" >"$(build_status_for "$lang" "$name")"
}

is_built() {
    local lang="$1" name="$2"
    local status_file
    status_file="$(build_status_for "$lang" "$name")"
    [ -f "$status_file" ] && [ "$(cat "$status_file")" = "ok" ] && [ -x "$(compiled_out_for "$lang" "$name")" ]
}

resource_stats_for() {
    local lang="$1" name="$2"
    printf "%s/resource_%s_%s.txt" "$TEMP_DIR" "$lang" "$name"
}

run_and_read_seconds() {
    local lang="$1" name="$2"
    # Keep name in "$@": bench_run.py takes it before the command.
    shift
    local resource_args=()
    if [ "$BENCH_RESOURCE_STATS" = "1" ]; then
        resource_args=(--resource-stats "$(resource_stats_for "$lang" "$name")")
    fi
    "$PYTHON" "$SCRIPT_DIR/bench_run.py" "${resource_args[@]}" "$BENCH_WARMUPS" "$BENCH_RUNS" "$@"
}

run_and_read_blorp_alloc_stats() {
    "$PYTHON" - "$@" <<'PY'
import re
import subprocess
import sys

cmd = sys.argv[1:]
leak_re = re.compile(
    r"blorp: leak check: ([0-9]+) allocs, ([0-9]+) releases, "
    r"([0-9]+) leaked, ([0-9]+) bytes"
)

proc = subprocess.run(
    cmd,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.PIPE,
    text=True,
)
if proc.returncode != 0:
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    raise SystemExit(proc.returncode)

match = None
for candidate in leak_re.finditer(proc.stderr):
    match = candidate
if match is None:
    sys.stderr.write("benchmark did not report a Blorp leak-check line\n")
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    raise SystemExit(125)

allocs, releases, leaked, bytes_allocated = match.groups()
print(
    f"allocs={allocs} releases={releases} leaked={leaked} "
    f"bytes={bytes_allocated}"
)
PY
}

write_c_timer() {
    local out="$1" name="$2" lang="$3" call_with_args="$4"
    local prototype="int bench_main(void);"
    local call="bench_main()"
    if [ "$call_with_args" = "1" ]; then
        prototype="int bench_main(int argc, char **argv);"
        call="bench_main(argc, argv)"
    fi
    cat >"$out" <<EOF
#include <stdio.h>
#include <sys/time.h>

$prototype

static double bench_now_seconds(void) {
    struct timeval tv;
    gettimeofday(&tv, 0);
    return (double)tv.tv_sec + ((double)tv.tv_usec / 1000000.0);
}

int main(int argc, char **argv) {
    double start = bench_now_seconds();
    int rc = $call;
    double elapsed = bench_now_seconds() - start;
    fflush(stdout);
    fprintf(stderr, "BENCH name=%s lang=%s seconds=%.9f\\n", "$name", "$lang", elapsed);
    return rc;
}
EOF
}

compile_blorp() {
    local name="$1" src="$2" out="$3"
    local bench_src="$TEMP_DIR/${name}_blorp.brp"
    local bench_c="$TEMP_DIR/${name}_blorp.c"
    local timer_c="$TEMP_DIR/${name}_blorp_timer.c"
    local timer_o="$TEMP_DIR/${name}_blorp_timer.o"
    local modes="0" memory_diagnostics obj binary

    cp "$src" "$bench_src" || return 1
    "$BLORP_COMPILER" compile "$bench_src" \
        --library-root "$PROJECT_DIR/blorp/standard_library" -o "$bench_c" >/dev/null || return 1
    [ -f "$bench_c" ] || return 1

    write_c_timer "$timer_c" "$name" "blorp" 1
    $CC -fwrapv -O2 -march=native -flto -pthread -c "$timer_c" -o "$timer_o" || return 1
    [ "$BENCH_ALLOC_STATS" = "1" ] && modes="0 1"
    for memory_diagnostics in $modes; do
        obj="$TEMP_DIR/${name}_blorp_${memory_diagnostics}.o"
        binary="$out"
        [ "$memory_diagnostics" = "1" ] && binary="$out.alloc"
        $CC -fwrapv -O2 -march=native -flto -pthread -Dmain=bench_main \
            "-DBLORP_MEMORY_DIAGNOSTICS=$memory_diagnostics" -c "$bench_c" -o "$obj" || return 1
        $CC -fwrapv -O2 -march=native -flto -pthread -o "$binary" "$obj" "$timer_o" -lm -lpthread || return 1
        [ -x "$binary" ] || return 1
    done
}

compile_c() {
    local name="$1" src="$2" out="$3"
    local obj="$TEMP_DIR/${name}_c.o"
    local timer_c="$TEMP_DIR/${name}_c_timer.c"
    local timer_o="$TEMP_DIR/${name}_c_timer.o"

    local call_with_args=1
    if grep -Eq 'int[[:space:]]+main[[:space:]]*\([[:space:]]*void[[:space:]]*\)' "$src"; then
        call_with_args=0
    fi

    write_c_timer "$timer_c" "$name" "c" "$call_with_args"
    $CC -O2 -march=native -flto -pthread -Dmain=bench_main -c "$src" -o "$obj"
    $CC -O2 -march=native -flto -pthread -c "$timer_c" -o "$timer_o"
    $CC -O2 -march=native -flto -pthread -o "$out" "$obj" "$timer_o" -lm
}

compile_go() {
    local name="$1" src="$2" out="$3"
    local work="$TEMP_DIR/go_$name"
    local main_go="$work/${name}.go"
    local timer_go="$work/bench_timer.go"

    mkdir -p "$work"
    "$PYTHON" - "$src" "$main_go" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
text = src.read_text()
rewritten, count = re.subn(r"\bfunc\s+main\s*\(\s*\)", "func benchMain()", text, count=1)
if count != 1:
    raise SystemExit(f"could not find Go main function in {src}")
out.write_text(rewritten)
PY
    cat >"$timer_go" <<EOF
package main

import (
    "fmt"
    "os"
    "time"
)

func main() {
    start := time.Now()
    benchMain()
    fmt.Fprintf(os.Stderr, "BENCH name=%s lang=go seconds=%.9f\\n", "$name", time.Since(start).Seconds())
}
EOF
    $GO build -o "$out" "$main_go" "$timer_go"
}

compile_ocaml() {
    local name="$1" src="$2" out="$3"
    local work="$TEMP_DIR/ocaml_$name"
    local main_ml="$work/${name}.ml"
    local timer_ml="$work/bench_timer.ml"
    local module_name

    mkdir -p "$work"
    module_name="$("$PYTHON" - "$name" <<'PY'
import sys
name = sys.argv[1]
print(name[:1].upper() + name[1:])
PY
)"
    "$PYTHON" - "$src" "$main_ml" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
text = src.read_text()
rewritten, count = re.subn(r"\blet\s*\(\s*\)\s*=", "let bench_main () =", text, count=1)
if count != 1:
    raise SystemExit(f"could not find OCaml entrypoint 'let () =' in {src}")
out.write_text(rewritten)
PY
    cat >"$timer_ml" <<EOF
let () =
  let start = Unix.gettimeofday () in
  let exit_code =
    try
      ${module_name}.bench_main ();
      0
    with exn ->
      prerr_endline (Printexc.to_string exn);
      1
  in
  flush stdout;
  Printf.eprintf "BENCH name=%s lang=ocaml seconds=%.9f\\n" "$name"
    (Unix.gettimeofday () -. start);
  exit exit_code
EOF
    "$OCAMLOPT" -O3 -unsafe -I +unix -I "$work" -o "$out" unix.cmxa "$main_ml" "$timer_ml"
}

build_compiled_lang() {
    local lang="$1" name="$2"
    local src out log status=0

    has_bench "$lang" "$name" || return 0
    if [ "$lang" = "go" ] && ! has_cmd "$GO"; then
        mark_build_status "$lang" "$name" "skip"
        return 0
    fi
    if [ "$lang" = "ocaml" ] && ! has_cmd "$OCAMLOPT"; then
        mark_build_status "$lang" "$name" "skip"
        return 0
    fi

    src="$(src_for "$lang" "$name")"
    out="$(compiled_out_for "$lang" "$name")"
    log="$(build_log_for "$lang" "$name")"

    case "$lang" in
        blorp) compile_blorp "$name" "$src" "$out" >"$log" 2>&1 ;;
        c) compile_c "$name" "$src" "$out" >"$log" 2>&1 ;;
        go) compile_go "$name" "$src" "$out" >"$log" 2>&1 ;;
        ocaml) compile_ocaml "$name" "$src" "$out" >"$log" 2>&1 ;;
        *) return 1 ;;
    esac || status=$?

    if [ "$status" -eq 0 ] && [ -x "$out" ]; then
        mark_build_status "$lang" "$name" "ok"
        return 0
    fi

    mark_build_status "$lang" "$name" "fail"
    if [ "$BENCH_VERBOSE" = "1" ]; then
        echo "Build failed: $lang/$name" >&2
        [ -s "$log" ] && cat "$log" >&2
    fi
    return 1
}

build_compiled_benchmarks() {
    local names="$1"
    local name lang total=0 failed=0

    for name in $names; do
        for lang in blorp c go ocaml; do
            has_bench "$lang" "$name" || continue
            if [ "$lang" = "go" ] && ! has_cmd "$GO"; then
                mark_build_status "$lang" "$name" "skip"
                continue
            fi
            if [ "$lang" = "ocaml" ] && ! has_cmd "$OCAMLOPT"; then
                mark_build_status "$lang" "$name" "skip"
                continue
            fi
            total=$((total + 1))
            if ! build_compiled_lang "$lang" "$name"; then
                failed=$((failed + 1))
            fi
        done
    done

    if [ "$total" -gt 0 ]; then
        if [ "$failed" -gt 0 ]; then
            echo "Build: compiled $((total - failed))/$total binaries up front ($failed failed; set BENCH_VERBOSE=1 for logs)"
        else
            echo "Build: compiled $total binaries up front"
        fi
    fi
}

write_python_runner() {
    local out="$1"
    cat >"$out" <<'PY'
import runpy
import sys
import time

bench_name = sys.argv[1]
bench_path = sys.argv[2]
bench_args = sys.argv[3:]
sys.argv = [bench_path, *bench_args]

start = time.perf_counter()
exit_code = 0
try:
    runpy.run_path(bench_path, run_name="__main__")
except SystemExit as exc:
    code = exc.code
    if code is None:
        exit_code = 0
    elif isinstance(code, int):
        exit_code = code
    else:
        print(code, file=sys.stderr)
        exit_code = 1
finally:
    sys.stdout.flush()
    print(f"BENCH name={bench_name} lang=python seconds={time.perf_counter() - start:.9f}", file=sys.stderr)

raise SystemExit(exit_code)
PY
}

fmt_speedup() {
    local target="$1" baseline="$2"
    "$PYTHON" -c "
t, b = $target, $baseline
if t <= 0 or b <= 0:
    print('-')
else:
    print(f'{b/t:.1f}x')
"
}

list_benchmarks() {
    for name in $ALL_BENCHMARKS $EXTRA_BENCHMARKS; do
        has_bench blorp "$name" || continue
        local langs="blorp"
        has_bench c "$name" && langs="$langs, C"
        has_bench go "$name" && langs="$langs, Go"
        has_bench ocaml "$name" && langs="$langs, OCaml"
        has_bench python "$name" && langs="$langs, Python"
        printf "  %-18s  (%s)\n" "$name" "$langs"
    done
}

run_built_lang() {
    local lang="$1" name="$2"
    shift 2
    local args=("$@")

    is_built "$lang" "$name" || return 1
    run_and_read_seconds "$lang" "$name" "$(compiled_out_for "$lang" "$name")" "${args[@]}"
}

run_blorp_alloc_stats() {
    local name="$1"
    shift
    local args=("$@")
    local out

    is_built blorp "$name" || return 1
    out="$(compiled_out_for blorp "$name").alloc"
    [ -x "$out" ] || return 1
    run_and_read_blorp_alloc_stats env BLORP_LEAK_CHECK=strict "$out" "${args[@]}"
}

run_python_lang() {
    local name="$1" src="$2"
    shift 2
    local args=("$@")
    local runner="$TEMP_DIR/python_bench_runner.py"

    write_python_runner "$runner"
    run_and_read_seconds python "$name" "$PYTHON" "$runner" "$name" "$src" "${args[@]}"
}

run_one() {
    local name="$1"
    local blorp_time="" ct="" gt="" ot="" pt=""
    local blorp_alloc_stats=""
    local args_text src
    local args=()

    has_bench blorp "$name" || {
        printf "  %-18s  SKIP (no blorp source)\n" "$name"
        return
    }

    args_text="$(bench_args_for "$name")"
    if [ -n "$args_text" ]; then
        # shellcheck disable=SC2206
        args=($args_text)
    fi

    printf "  %-18s" "$name"

    if blorp_time=$(run_built_lang blorp "$name" "${args[@]}" 2>/dev/null); then
        printf "  %9ss" "$blorp_time"
        if [ "$BENCH_ALLOC_STATS" = "1" ]; then
            if ! blorp_alloc_stats=$(run_blorp_alloc_stats "$name" "${args[@]}"); then
                BENCH_FAILED=1
                blorp_alloc_stats="allocation run FAILED"
            fi
        fi
    else
        BENCH_FAILED=1
        printf "  %8s" "FAIL"
    fi

    if has_bench c "$name"; then
        if ct=$(run_built_lang c "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$ct"
        else
            BENCH_FAILED=1
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if has_bench go "$name" && has_cmd "$GO"; then
        if gt=$(run_built_lang go "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$gt"
        else
            BENCH_FAILED=1
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if has_bench ocaml "$name" && has_cmd "$OCAMLOPT"; then
        if ot=$(run_built_lang ocaml "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$ot"
        else
            BENCH_FAILED=1
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if has_bench python "$name" && python_cmd_runs "$PYTHON"; then
        src="$(src_for python "$name")"
        if pt=$(run_python_lang "$name" "$src" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$pt"
        else
            BENCH_FAILED=1
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if [ -n "$blorp_time" ]; then
        local notes=""
        [ -n "$blorp_alloc_stats" ] && notes="blorp: $blorp_alloc_stats"
        local lang resource_stats
        for lang in blorp c go ocaml python; do
            resource_stats="$(resource_stats_for "$lang" "$name")"
            [ -f "$resource_stats" ] || continue
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}$lang: $(cat "$resource_stats")"
        done
        case "$name" in
            list_ops|compiler_emit) notes="${notes:+$notes }(provisional: current libraries)" ;;
            compiler_ast|binary_trees) notes="${notes:+$notes }(provisional: representations differ)" ;;
        esac
        # A speedup is that language's elapsed time divided by Blorp's: a value
        # above 1.0x means Blorp was faster.
        if [ -n "$ct" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs C: $(fmt_speedup "$blorp_time" "$ct")"
        fi
        if [ -n "$gt" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs Go: $(fmt_speedup "$blorp_time" "$gt")"
        fi
        if [ -n "$ot" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs OCaml: $(fmt_speedup "$blorp_time" "$ot")"
        fi
        if [ -n "$pt" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs Py: $(fmt_speedup "$blorp_time" "$pt")"
        fi
        [ -n "$notes" ] && printf "   %s" "$notes"
    fi

    echo ""
}

FILTER="${1:-all}"
RUN_BENCHMARKS=""

if [ "$FILTER" = "--list" ] || [ "$FILTER" = "-l" ]; then
    echo "Available benchmarks:"
    list_benchmarks
    exit 0
fi

if [ "$FILTER" = "--help" ] || [ "$FILTER" = "-h" ]; then
    echo "Usage: bash benchmarks/bench.sh [benchmark|all|--list]"
    echo ""
    echo "Available benchmarks:"
    list_benchmarks
    exit 0
fi

if [ "$BENCH_RESOURCE_STATS" = "1" ] && ! /usr/bin/time -l true 2>&1 | grep -q "instructions retired"; then
    die "BENCH_RESOURCE_STATS=1 needs a /usr/bin/time -l that reports instructions retired (macOS)"
fi

echo ""
echo "blorp Benchmark Suite"
echo "====================="
echo "Timing: in-process BENCH markers from language-specific runners"
echo "blorp:  $BLORP_COMPILER"
if [ "$BENCH_ALLOC_STATS" = "1" ]; then
    echo "Allocation runs: blorp counts allocator calls; bytes are live at exit."
fi
if [ "$BENCH_RESOURCE_STATS" = "1" ]; then
    echo "Resource stats: whole-process /usr/bin/time -l; minimum instructions and maximum peak RSS over timed runs."
fi
echo "C:     $($CC --version 2>&1 | head -1)"
has_cmd "$GO" && echo "Go:    $($GO version 2>&1 | sed 's/go version //')"
has_cmd "$OCAMLOPT" && echo "OCaml: $($OCAMLOPT -version 2>&1 | sed 's/^/ /')"
has_cmd "$PYTHON" && echo "Python:$($PYTHON --version 2>&1 | sed 's/^/ /')"

if [ "$FILTER" = "all" ]; then
    RUN_BENCHMARKS="$ALL_BENCHMARKS"
else
    is_known_benchmark "$FILTER" && has_bench blorp "$FILTER" || die "unknown benchmark: $FILTER"
    RUN_BENCHMARKS="$FILTER"
fi

[ -x "$BLORP_COMPILER" ] ||
    die "BLORP_COMPILER is not executable: $BLORP_COMPILER; run 'make -C blorp compiler' or set BLORP_COMPILER"

echo ""

build_compiled_benchmarks "$RUN_BENCHMARKS"
echo ""

printf "  %-18s  %10s  %10s  %10s  %10s  %10s\n" "Benchmark" "blorp" "C" "Go" "OCaml" "Python"
printf "  %-18s  %10s  %10s  %10s  %10s  %10s\n" "---------" "-----" "-" "--" "-----" "------"

for name in $RUN_BENCHMARKS; do
    run_one "$name"
done

if [ "$BENCH_FAILED" -ne 0 ]; then
    exit 1
fi

echo ""
echo "Done."
