#!/usr/bin/env python3
"""Render benchmarks/results/split_bench_raw.json into markdown tables."""
import json
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "benchmarks/results/split_bench_raw.json"
d = json.load(open(path))
cells = [r for r in d if r.get("kind") == "cell"]
scs = [r for r in d if r.get("kind") == "self_compile"]

print("| N | OPT | runs | serial CPU (median s) | parallel wall (median s, P=min(N,10)) | peak RSS (median MB) | link (median s) | binary size (MB) | smoke |")
print("|---|---|---|---|---|---|---|---|---|")
for r in sorted(cells, key=lambda r: (r["opt"], r["n"])):
    print(f"| {r['n']} | {r['opt']} | {r['runs']} | {r['serial_cpu_median']:.1f} | "
          f"{r['parallel_wall_median']:.1f} | {r['peak_rss_median']/1e6:.0f} | "
          f"{r['link_real_median']:.2f} | {r['bin_size']/1e6:.1f} | {r.get('smoke_ok')} |")

print()
print("Per-run raw values (serial CPU / parallel wall), for variance:")
for r in sorted(cells, key=lambda r: (r["opt"], r["n"])):
    sc = ", ".join(f"{x:.1f}" for x in r["serial_cpu_all"])
    pw = ", ".join(f"{x:.1f}" for x in r["parallel_wall_all"])
    print(f"- N={r['n']} {r['opt']}: serial=[{sc}]  parallel=[{pw}]")

print()
print("Self-compile (-O2 binaries), user CPU median over runs:")
for r in sorted(scs, key=lambda r: r["n"]):
    print(f"- N={r['n']}: user_median={r['user_median']:.2f}s real_median={r['real_median']:.2f}s "
          f"all={['%.2f'%x for x in r['user_all']]}")
