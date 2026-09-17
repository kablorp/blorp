#!/usr/bin/env python3
"""Benchmark: does splitting the generated Blorp CLI C file into N translation
units speed up the host C compile, at -O0 and -O2, and what does it cost?

This script drives scripts/split-generated-c to produce N-way splits,
then for each (N, OPT) cell measures, using `/usr/bin/time -l`:
  - per-TU user/sys/wall CPU and peak RSS (each TU compiled alone, serially)
  - total serial CPU (sum of user+sys across all TUs in the cell)
  - parallel wall clock, compiling all TUs at once with parallelism
    min(N, --jobs)
  - link time and final binary size

It also (with --self-compile) times the resulting bin/blorp doing a
self-compile-to-C, to see whether losing cross-TU inlining at -O2 makes the
*resulting* compiler slower.

Results are written as JSON (one record per (N, OPT) cell, plus self-compile
records) to --results-json, so benchmarks/results/*.md can be built from a
stable machine-readable log instead of re-parsing terminal output.

Usage:
    benchmarks/bench_split_c.py \\
        --source blorp/build/_build/blorp-cli/blorp_cli_main.c \\
        --split-dir /tmp/split_out --results-json benchmarks/results/split_bench.json \\
        --ns 1 2 4 8 16 --opts -O0 -O2 --runs 3
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INCLUDE_FLAGS = [
    "-Iblorp/src/compiler/stage_01_generated_inputs",
    "-Iblorp/src/compiler/stage_04_modules",
    "-Iblorp/src/compiler/stage_06_typecheck/graph",
    "-Iblorp/src/compiler/stage_06_typecheck/type_system",
    "-Iblorp/src",
    "-Iblorp/src/lib",
    "-Iblorp/src/lsp/server",
    "-Iblorp/src/test",
]
RUNTIME_DECL = "blorp/src/lib/runtime/native/runtime_decl.c"
RUNTIME_SOURCES_C = "blorp/build/_build/blorp-cli/runtime_sources.c"
LSP_NATIVE_RUNTIME_C = "blorp/src/lsp/server/native_runtime.c"

# `/usr/bin/time -l` on macOS prints "<real> real  <user> user  <sys> sys" all
# on one line, then a column of "<value>  <label...>" lines below it -- these
# regexes search anywhere in a line (not anchored to line-start) to handle
# both layouts.
TIME_RE = {
    "real": re.compile(r"([\d.]+)\s+real\b"),
    "user": re.compile(r"([\d.]+)\s+user\b"),
    "sys": re.compile(r"([\d.]+)\s+sys\b"),
    "maxrss": re.compile(r"(\d+)\s+maximum resident set size"),
}


def run_timed(cmd, cwd=ROOT):
    """Run `cmd` under /usr/bin/time -l; return (rc, metrics dict, stdout+stderr)."""
    full = ["/usr/bin/time", "-l"] + cmd
    p = subprocess.run(full, cwd=cwd, capture_output=True, text=True)
    metrics = {"real": None, "user": None, "sys": None, "maxrss": None}
    for line in p.stderr.splitlines():
        for key, rx in TIME_RE.items():
            if metrics[key] is not None:
                continue
            m = rx.search(line)
            if m:
                metrics[key] = float(m.group(1)) if key != "maxrss" else int(m.group(1))
    missing = [k for k, v in metrics.items() if v is None]
    if missing:
        raise RuntimeError(f"could not parse /usr/bin/time -l output for {missing}: {p.stderr!r}")
    return p.returncode, metrics, p.stdout + p.stderr


def median(xs):
    return statistics.median(xs) if xs else None


def ensure_splits(source, split_dir, ns):
    need = [n for n in ns if not os.path.isdir(os.path.join(split_dir, f"n{n}"))]
    if need:
        cmd = [sys.executable, os.path.join(ROOT, "scripts", "split-generated-c"),
               source, split_dir]
        for n in need:
            cmd += ["-n", str(n)]
        print("Splitting:", " ".join(cmd), file=sys.stderr)
        subprocess.run(cmd, cwd=ROOT, check=True)


def tu_files(split_dir, n):
    d = os.path.join(split_dir, f"n{n}")
    fs = sorted(
        f for f in os.listdir(d) if f.startswith("split_body_") and f.endswith(".c")
    )
    return [os.path.join(d, f) for f in fs]


def compile_flags(opt):
    return [
        "cc", opt, "-fwrapv", "-pipe", "-w",
        "-DBLORP_COMPILER_RUNTIME_SOURCES=1",
        "-include", RUNTIME_DECL,
    ] + INCLUDE_FLAGS


def compile_one_tu(src, opt, obj_out):
    cmd = compile_flags(opt) + ["-c", src, "-o", obj_out]
    return run_timed(cmd)


def build_runtime_object(opt):
    """The fixed runtime.o the real Makefile always links in (unaffected by
    the split; excluded from the split's own totals but included in link
    steps to mirror the real build). Cached by a hash of its sources plus
    the exact flags used to build it, the same way the Makefile's own
    runtime-<hash>.o is content-addressed -- so a later run after runtime.c
    (or minicoro.h, or these flags) changes always rebuilds instead of
    silently linking a stale object."""
    cmd = [
        "cc", opt, "-fwrapv", "-pipe", "-w", "-DMINICORO_IMPL",
        "-DBLORP_COMPILER_RUNTIME_SOURCES=1",
        "-include", "blorp/src/lib/runtime/native/minicoro.h",
        "-c", "blorp/src/lib/runtime/native/runtime.c",
    ]
    h = hashlib.sha256()
    for src in ("blorp/src/lib/runtime/native/runtime.c",
                "blorp/src/lib/runtime/native/minicoro.h"):
        with open(os.path.join(ROOT, src), "rb") as f:
            h.update(f.read())
    h.update("\0".join(cmd).encode())
    out = os.path.join("/tmp", f"bench_split_runtime-{h.hexdigest()}.o")
    if os.path.exists(out):
        return out
    subprocess.run(cmd + ["-o", out], cwd=ROOT, check=True)
    return out


def bench_cell(split_dir, n, opt, jobs, runs, keep_objs_dir):
    files = tu_files(split_dir, n)
    assert len(files) == n, f"expected {n} TUs, found {len(files)}"
    runtime_obj = build_runtime_object("-O2")

    trials = []
    for run_idx in range(runs):
        cell_dir = os.path.join(keep_objs_dir, f"n{n}_{opt.lstrip('-')}_run{run_idx}")
        serial_dir = os.path.join(cell_dir, "serial")
        os.makedirs(serial_dir, exist_ok=True)
        per_tu = []
        # Serial, one at a time: authoritative per-TU CPU/RSS + serial-sum CPU.
        for f in files:
            obj = os.path.join(serial_dir, os.path.basename(f) + ".o")
            rc, metrics, out = compile_one_tu(f, opt, obj)
            if rc != 0:
                print(out, file=sys.stderr)
                raise RuntimeError(f"compile failed: {f} ({opt})")
            per_tu.append({"file": os.path.basename(f), **metrics})

        serial_cpu = sum((m["user"] or 0) + (m["sys"] or 0) for m in per_tu)
        serial_wall_sum = sum((m["real"] or 0) for m in per_tu)
        peak_rss = max((m["maxrss"] or 0) for m in per_tu)

        # Parallel wall-clock: recompile fresh objects with xargs -P.
        par_dir = os.path.join(cell_dir, "parallel")
        os.makedirs(par_dir, exist_ok=True)
        par_objs = [os.path.join(par_dir, os.path.basename(f) + ".o") for f in files]
        t0 = time.time()
        with ThreadPoolExecutor(max_workers=min(n, jobs)) as ex:
            def _compile(args):
                f, o = args
                cmd = compile_flags(opt) + ["-c", f, "-o", o]
                return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            results = list(ex.map(_compile, zip(files, par_objs)))
        parallel_wall = time.time() - t0
        for r in results:
            if r.returncode != 0:
                print(r.stdout, r.stderr, file=sys.stderr)
                raise RuntimeError("parallel compile failed")

        # Link.
        bin_out = os.path.join(cell_dir, "blorp_split")
        link_cmd = [
            "cc", opt, "-fwrapv", "-pipe", "-w", "-DBLORP_COMPILER_RUNTIME_SOURCES=1",
        ] + par_objs + [runtime_obj, RUNTIME_SOURCES_C, LSP_NATIVE_RUNTIME_C,
                          "-lm", "-lpthread", "-o", bin_out]
        rc, link_metrics, out = run_timed(link_cmd)
        if rc != 0:
            print(out, file=sys.stderr)
            raise RuntimeError("link failed")
        bin_size = os.path.getsize(bin_out)

        trials.append({
            "per_tu": per_tu,
            "serial_cpu": serial_cpu,
            "serial_wall_sum": serial_wall_sum,
            "peak_rss": peak_rss,
            "parallel_wall": parallel_wall,
            "link_user": link_metrics["user"],
            "link_sys": link_metrics["sys"],
            "link_real": link_metrics["real"],
            "link_maxrss": link_metrics["maxrss"],
            "bin_size": bin_size,
            "bin_path": bin_out,
        })
        # Clean serial objs to save disk; keep parallel objs + binary (needed
        # for the smoke test on at least the last trial).
        shutil.rmtree(serial_dir, ignore_errors=True)
        if run_idx < runs - 1:
            # Earlier trials' binaries aren't needed once recorded.
            shutil.rmtree(par_dir, ignore_errors=True)
            try:
                os.remove(bin_out)
            except OSError:
                pass

    return {
        "n": n, "opt": opt,
        "runs": runs,
        "serial_cpu_median": median([t["serial_cpu"] for t in trials]),
        "serial_cpu_all": [t["serial_cpu"] for t in trials],
        "parallel_wall_median": median([t["parallel_wall"] for t in trials]),
        "parallel_wall_all": [t["parallel_wall"] for t in trials],
        "peak_rss_median": median([t["peak_rss"] for t in trials]),
        "link_real_median": median([t["link_real"] for t in trials]),
        "link_user_median": median([t["link_user"] for t in trials]),
        "bin_size": trials[-1]["bin_size"],
        "last_bin_path": trials[-1]["bin_path"],
        "per_tu_last_trial": trials[-1]["per_tu"],
    }


def smoke_test(bin_path):
    cmd = ["blorp/test/cli/test_cli.sh", "--smoke", "--timeout", "60"]
    env = dict(os.environ, BLORP_BIN=bin_path)
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    return p.returncode == 0, p.stdout[-2000:] + p.stderr[-2000:]


SELF_COMPILE_OUT = "/tmp/bench_split_self_compile_out.c"
SELF_COMPILE_CMD = [
    "compile", "--std-dir", "standard_library/src", "--no-format",
    "--no-embed-runtime", "-o", SELF_COMPILE_OUT, "blorp/src/main.brp",
]


def bench_self_compile(bin_path, runs):
    if runs < 1:
        raise ValueError("bench_self_compile needs at least 1 run")
    times = []
    for _ in range(runs):
        rc, metrics, out = run_timed([bin_path] + SELF_COMPILE_CMD)
        if rc != 0:
            print(out, file=sys.stderr)
            raise RuntimeError(f"self-compile failed for {bin_path}")
        times.append(metrics)
    return {
        "user_median": median([m["user"] for m in times]),
        "real_median": median([m["real"] for m in times]),
        "user_all": [m["user"] for m in times],
        "real_all": [m["real"] for m in times],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default="blorp/build/_build/blorp-cli/blorp_cli_main.c")
    ap.add_argument("--split-dir", default="/tmp/split_out")
    ap.add_argument("--objs-dir", default="/tmp/bench_split_objs")
    ap.add_argument("--results-json", default="benchmarks/results/split_bench_raw.json")
    ap.add_argument("--ns", nargs="+", type=int, default=[1, 2, 4, 8, 16])
    ap.add_argument("--opts", nargs="+", default=["O0", "O2"],
                     help="optimization levels, with or without leading '-' (e.g. O2 or -O2)")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--jobs", type=int, default=10)
    ap.add_argument("--smoke", action="store_true", help="run CLI smoke test on each built binary (serially)")
    ap.add_argument("--self-compile", action="store_true", help="also bench self-compile-to-C for the built binaries")
    ap.add_argument("--self-compile-runs", type=int, default=3)
    ap.add_argument("--skip-cells", nargs="*", default=[], help="e.g. 1:-O2 to skip a cell")
    args = ap.parse_args()
    args.opts = [o if o.startswith("-") else "-" + o for o in args.opts]

    ensure_splits(args.source, args.split_dir, args.ns)
    os.makedirs(args.objs_dir, exist_ok=True)
    os.makedirs(os.path.dirname(args.results_json), exist_ok=True)

    results = []
    if os.path.exists(args.results_json):
        with open(args.results_json) as f:
            results = json.load(f)

    def already_have(n, opt):
        return any(r.get("n") == n and r.get("opt") == opt and r.get("kind") == "cell" for r in results)

    skip = set(args.skip_cells)
    for opt in args.opts:
        for n in args.ns:
            key = f"{n}:{opt}"
            if key in skip:
                print(f"Skipping {key} (requested)", file=sys.stderr)
                continue
            if already_have(n, opt):
                print(f"Already have {key}, skipping", file=sys.stderr)
                continue
            print(f"=== Benchmarking n={n} opt={opt} ===", file=sys.stderr)
            t0 = time.time()
            cell = bench_cell(args.split_dir, n, opt, args.jobs, args.runs, args.objs_dir)
            cell["kind"] = "cell"
            cell["wall_to_bench_cell"] = time.time() - t0
            if args.smoke:
                ok, log = smoke_test(cell["last_bin_path"])
                cell["smoke_ok"] = ok
                if not ok:
                    cell["smoke_log_tail"] = log
                    print(f"SMOKE FAILED for n={n} opt={opt}:\n{log}", file=sys.stderr)
            results.append(cell)
            with open(args.results_json, "w") as f:
                json.dump(results, f, indent=2)
            print(f"n={n} opt={opt}: serial_cpu={cell['serial_cpu_median']:.1f}s "
                  f"parallel_wall={cell['parallel_wall_median']:.1f}s "
                  f"link={cell['link_real_median']:.1f}s bin={cell['bin_size']/1e6:.1f}MB",
                  file=sys.stderr)

    if args.self_compile:
        for r in results:
            if r.get("kind") != "cell" or r["opt"] != "-O2":
                continue
            sc_key = f"self_compile:{r['n']}"
            if any(x.get("kind") == "self_compile" and x.get("n") == r["n"] for x in results):
                continue
            print(f"=== Self-compile bench for n={r['n']} (-O2) ===", file=sys.stderr)
            sc = bench_self_compile(r["last_bin_path"], args.self_compile_runs)
            sc["kind"] = "self_compile"
            sc["n"] = r["n"]
            results.append(sc)
            with open(args.results_json, "w") as f:
                json.dump(results, f, indent=2)
            print(f"n={r['n']} self-compile user_median={sc['user_median']}s", file=sys.stderr)

    print(f"Wrote {args.results_json}", file=sys.stderr)


if __name__ == "__main__":
    main()
