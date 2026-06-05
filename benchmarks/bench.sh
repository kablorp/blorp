#!/bin/bash
# blorp Benchmark Suite
#
# Layout:
#   benchmarks/blorp/<name>.brp
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
# Environment:
#   PYTHON=python3.11                  bash benchmarks/bench.sh   # Use specific Python
#   PYTHON_CONCURRENCY=python3.14t     bash benchmarks/bench.sh   # Free-threaded Python for concurrency rows
#   GO=go1.22                          bash benchmarks/bench.sh   # Use specific Go
#   OCAMLOPT=ocamlopt                  bash benchmarks/bench.sh   # Use specific OCaml native compiler
#   CC=gcc                             bash benchmarks/bench.sh   # Use specific C compiler
#   BENCH_THREADS=4                    bash benchmarks/bench.sh   # Worker/task width for concurrency rows
#   BLORP_THREADS=4                    bash benchmarks/bench.sh   # Blorp runtime thread width for concurrency rows
#   GOMAXPROCS=4                       bash benchmarks/bench.sh   # Go runtime parallelism for concurrency rows
#   BENCH_RUNS=5                       bash benchmarks/bench.sh   # Timed runs per language (default: 1)
#   BENCH_WARMUPS=1                    bash benchmarks/bench.sh   # Untimed warmup runs (default: 0)
#   BENCH_ALLOC_STATS=1                bash benchmarks/bench.sh   # Add Blorp allocation/release counts
#   BENCH_VERBOSE=1                    bash benchmarks/bench.sh   # Print build logs on failures

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BLORP="$PROJECT_DIR/blorp"
PYTHON="${PYTHON:-python3}"
if [ "${PYTHON_CONCURRENCY+x}" ]; then
    PYTHON_CONCURRENCY_DEFAULTED=0
else
    PYTHON_CONCURRENCY="python3.14t"
    PYTHON_CONCURRENCY_DEFAULTED=1
fi
GO="${GO:-go}"
OCAMLOPT="${OCAMLOPT:-ocamlopt}"
CC="${CC:-cc}"
BENCH_THREADS="${BENCH_THREADS:-4}"
BENCH_RUNS="${BENCH_RUNS:-1}"
BENCH_WARMUPS="${BENCH_WARMUPS:-0}"
BENCH_ALLOC_STATS="${BENCH_ALLOC_STATS:-0}"
BENCH_VERBOSE="${BENCH_VERBOSE:-0}"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT
export BENCH_THREADS
BLORP_CONCURRENCY_THREADS="${BLORP_THREADS:-$BENCH_THREADS}"
GO_CONCURRENCY_THREADS="${GOMAXPROCS:-$BENCH_THREADS}"

# Ordered benchmark list (determines display order)
ALL_BENCHMARKS="numeric_loop fib string array_sum array_ops dict_ops list_ops set_ops threaded_cpu_map channel_pipeline sleep_fanout options simd nbody binary_trees fannkuch spectral_norm mandelbrot knucleotide reverse_complement compiler_ast compiler_symbols compiler_emit"
EXTRA_BENCHMARKS="numeric_vector paradigms particle_gravity virtual_threads"
CONCURRENCY_BENCHMARKS="threaded_cpu_map channel_pipeline sleep_fanout"
SPEEDUP_SUPPRESSED_BENCHMARKS=""

die() { echo "error: $1" >&2; exit 1; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

python_cmd_runs() {
    "$1" -c 'import sys' >/dev/null 2>&1
}

resolve_default_python_concurrency() {
    python_cmd_runs "$PYTHON_CONCURRENCY" && return 0
    [ "$PYTHON_CONCURRENCY_DEFAULTED" = "1" ] || return 1
    has_cmd pyenv || return 1

    local version path
    version="$(pyenv versions --bare 2>/dev/null | awk '/^3[.]14.*t$/ { candidate = $0 } END { print candidate }')"
    [ -n "$version" ] || return 1
    path="$(PYENV_VERSION="$version" pyenv which python3.14t 2>/dev/null)" || return 1
    [ -n "$path" ] || return 1
    PYTHON_CONCURRENCY="$path"
    python_cmd_runs "$PYTHON_CONCURRENCY"
}

is_speedup_suppressed_benchmark() {
    local needle="$1"
    case " $SPEEDUP_SUPPRESSED_BENCHMARKS " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

is_concurrency_benchmark() {
    local needle="$1"
    case " $CONCURRENCY_BENCHMARKS " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

contains_concurrency_benchmark() {
    local name
    for name in "$@"; do
        is_concurrency_benchmark "$name" && return 0
    done
    return 1
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

run_and_read_seconds() {
    "$PYTHON" - "$BENCH_WARMUPS" "$BENCH_RUNS" "$@" <<'PY'
import re
import subprocess
import sys

warmups = int(sys.argv[1])
runs = int(sys.argv[2])
cmd = sys.argv[3:]

bench_re = re.compile(r"^BENCH\s+.*(?:seconds=([0-9]+(?:\.[0-9]+)?)|micros=([0-9]+))", re.M)

def run_once():
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
    for candidate in bench_re.finditer(proc.stderr):
        match = candidate
    if match is None:
        sys.stderr.write("benchmark did not report a BENCH timing line\n")
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise SystemExit(125)

    seconds, micros = match.groups()
    if seconds is not None:
        return float(seconds)
    return float(micros) / 1_000_000.0

for _ in range(warmups):
    run_once()

samples = [run_once() for _ in range(runs)]
print(f"{min(samples):.4f}")
PY
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
    local obj="$TEMP_DIR/${name}_blorp.o"
    local timer_c="$TEMP_DIR/${name}_blorp_timer.c"
    local timer_o="$TEMP_DIR/${name}_blorp_timer.o"
    local helper_src="$SCRIPT_DIR/blorp/support"

    cp "$src" "$bench_src"
    if [ -d "$helper_src" ]; then
        cp -R "$helper_src" "$TEMP_DIR/support"
    fi
    (
        cd "$PROJECT_DIR"
        "$BLORP" compile "$bench_src" >/dev/null
    )
    [ -f "$bench_c" ] || return 1

    write_c_timer "$timer_c" "$name" "blorp" 1
    $CC -fwrapv -O3 -march=native -flto -pthread -Dmain=bench_main -c "$bench_c" -o "$obj"
    $CC -fwrapv -O3 -march=native -flto -pthread -c "$timer_c" -o "$timer_o"
    $CC -fwrapv -O3 -march=native -flto -pthread -o "$out" "$obj" "$timer_o" -lm -lpthread
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
    $CC -O3 -march=native -flto -pthread -Dmain=bench_main -c "$src" -o "$obj"
    $CC -O3 -march=native -flto -pthread -c "$timer_c" -o "$timer_o"
    $CC -O3 -march=native -flto -pthread -o "$out" "$obj" "$timer_o" -lm
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
    "$OCAMLOPT" -O3 -unsafe -I +unix -I +threads -I "$work" -o "$out" unix.cmxa threads.cmxa "$main_ml" "$timer_ml"
}

build_compiled_lang() {
    local lang="$1" name="$2"
    local src out log

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
    esac

    if [ -x "$out" ]; then
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
    local out

    is_built "$lang" "$name" || return 1
    out="$(compiled_out_for "$lang" "$name")"
    if is_concurrency_benchmark "$name"; then
        case "$lang" in
            blorp)
                run_and_read_seconds env "BLORP_THREADS=$BLORP_CONCURRENCY_THREADS" "$out" "${args[@]}"
                return
                ;;
            go)
                run_and_read_seconds env "GOMAXPROCS=$GO_CONCURRENCY_THREADS" "$out" "${args[@]}"
                return
                ;;
        esac
    fi
    run_and_read_seconds "$out" "${args[@]}"
}

run_blorp_alloc_stats() {
    local name="$1"
    shift
    local args=("$@")
    local out

    is_built blorp "$name" || return 1
    out="$(compiled_out_for blorp "$name")"
    if is_concurrency_benchmark "$name"; then
        run_and_read_blorp_alloc_stats env \
            "BLORP_THREADS=$BLORP_CONCURRENCY_THREADS" \
            "BLORP_LEAK_CHECK=1" \
            "$out" "${args[@]}"
    else
        run_and_read_blorp_alloc_stats env \
            "BLORP_LEAK_CHECK=1" \
            "$out" "${args[@]}"
    fi
}

run_python_lang() {
    local name="$1" src="$2"
    shift 2
    local args=("$@")
    local runner="$TEMP_DIR/python_bench_runner.py"
    local py="$PYTHON"
    local py_args=()

    write_python_runner "$runner"
    if is_concurrency_benchmark "$name"; then
        resolve_default_python_concurrency || return 1
        py="$PYTHON_CONCURRENCY"
        py_args=(-X gil=0)
        "$py" "${py_args[@]}" - <<'PY'
import sys
import sysconfig

if sys.version_info < (3, 14):
    raise SystemExit("Python concurrency benchmarks require Python 3.14+")

if str(sysconfig.get_config_var("Py_GIL_DISABLED")) != "1":
    raise SystemExit("Python concurrency benchmarks require a free-threaded build")

is_gil_enabled = getattr(sys, "_is_gil_enabled", None)
if callable(is_gil_enabled) and is_gil_enabled():
    raise SystemExit("Python concurrency benchmarks require the GIL disabled")
PY
    fi

    run_and_read_seconds "$py" "${py_args[@]}" "$runner" "$name" "$src" "${args[@]}"
}

run_one() {
    local name="$1"
    local bt="" ct="" gt="" ot="" pt=""
    local blorp_alloc_stats=""
    local args_text
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

    if bt=$(run_built_lang blorp "$name" "${args[@]}" 2>/dev/null); then
        printf "  %9ss" "$bt"
        if [ "$BENCH_ALLOC_STATS" = "1" ]; then
            blorp_alloc_stats="$(run_blorp_alloc_stats "$name" "${args[@]}" 2>/dev/null || true)"
        fi
    else
        printf "  %8s" "FAIL"
    fi

    if has_bench c "$name"; then
        if ct=$(run_built_lang c "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$ct"
        else
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if has_bench go "$name" && has_cmd "$GO"; then
        if gt=$(run_built_lang go "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$gt"
        else
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if has_bench ocaml "$name" && has_cmd "$OCAMLOPT"; then
        if ot=$(run_built_lang ocaml "$name" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$ot"
        else
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    local py_cmd="$PYTHON"
    is_concurrency_benchmark "$name" && py_cmd="$PYTHON_CONCURRENCY"
    if has_bench python "$name" && python_cmd_runs "$py_cmd"; then
        src="$(src_for python "$name")"
        if pt=$(run_python_lang "$name" "$src" "${args[@]}" 2>/dev/null); then
            printf "  %9ss" "$pt"
        else
            printf "  %8s" "FAIL"
        fi
    else
        printf "  %8s" "-"
    fi

    if is_speedup_suppressed_benchmark "$name"; then
        printf "   speedups suppressed (see benchmarks/AUDIT.md)"
    elif [ -n "$bt" ]; then
        local notes=""
        [ -n "$blorp_alloc_stats" ] && notes="$blorp_alloc_stats"
        if [ -n "$ct" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs C: $(fmt_speedup "$bt" "$ct")"
        fi
        if [ -n "$gt" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs Go: $(fmt_speedup "$bt" "$gt")"
        fi
        if [ -n "$ot" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs OCaml: $(fmt_speedup "$bt" "$ot")"
        fi
        if [ -n "$pt" ]; then
            [ -n "$notes" ] && notes="$notes, "
            notes="${notes}vs Py: $(fmt_speedup "$bt" "$pt")"
        fi
        [ -n "$notes" ] && printf "   %s" "$notes"
    fi

    echo ""
}

[ ! -f "$BLORP" ] && die "blorp binary not found. Run 'make' first."

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

echo ""
echo "blorp Benchmark Suite"
echo "====================="
echo "Timing: in-process BENCH markers from language-specific runners"
echo "blorp: $BLORP"
echo "C:     $($CC --version 2>&1 | head -1)"
has_cmd "$GO" && echo "Go:    $($GO version 2>&1 | sed 's/go version //')"
has_cmd "$OCAMLOPT" && echo "OCaml: $($OCAMLOPT -version 2>&1 | sed 's/^/ /')"
has_cmd "$PYTHON" && echo "Python:$($PYTHON --version 2>&1 | sed 's/^/ /')"

if [ "$FILTER" = "all" ]; then
    RUN_BENCHMARKS="$ALL_BENCHMARKS"
else
    has_bench blorp "$FILTER" || die "unknown benchmark: $FILTER"
    RUN_BENCHMARKS="$FILTER"
fi

if contains_concurrency_benchmark $RUN_BENCHMARKS; then
    resolve_default_python_concurrency || true
    python_cmd_runs "$PYTHON_CONCURRENCY" && echo "Python concurrency: $($PYTHON_CONCURRENCY --version 2>&1 | sed 's/^/ /')"
    echo "BENCH_THREADS: $BENCH_THREADS"
    echo "BLORP_THREADS: $BLORP_CONCURRENCY_THREADS"
    echo "GOMAXPROCS:    $GO_CONCURRENCY_THREADS"
fi
echo ""

build_compiled_benchmarks "$RUN_BENCHMARKS"
echo ""

printf "  %-18s  %10s  %10s  %10s  %10s  %10s\n" "Benchmark" "blorp" "C" "Go" "OCaml" "Python"
printf "  %-18s  %10s  %10s  %10s  %10s  %10s\n" "---------" "-----" "-" "--" "-----" "------"

for name in $RUN_BENCHMARKS; do
    run_one "$name"
done

echo ""
echo "Done."
