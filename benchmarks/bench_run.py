#!/usr/bin/env python3
"""Run benchmark samples and read the in-process BENCH timing marker.

With --resource-stats PATH, every timed sample also runs under macOS
`/usr/bin/time -l`, and PATH receives the minimum retired instructions and the
maximum peak resident set size across those samples. Both cover the whole
process, including startup, unlike the in-process BENCH time.
"""

from __future__ import annotations

import re
import subprocess
import sys
from dataclasses import dataclass


EXPECTED_OUTPUTS = {
    "fib": "Fib(40) = 102334155\n",
    "numeric_loop": "Total Collatz steps: 131434272\n",
    "array_sum": "Completed 10000 iterations, total: 4995000000\n",
    "array_ops": "Completed 10000 iterations, final sum: 44955000000\n",
    "dict_ops": (
        "build: done\n"
        "lookup_hit checksum: 34996500000\n"
        "lookup_miss count: 1000000\n"
        "remove count: 1000000\n"
        "iterate sum: 349965000000\n"
    ),
    "list_ops": (
        "append checksum: 5000000\n"
        "sort checksum: 4999000\n"
        "filter checksum: 2500000\n"
        "fold checksum: 99990000000\n"
        "reverse checksum: 10000000\n"
        "concat checksum: 10000000\n"
    ),
    "set_ops": (
        "build: done\n"
        "contains_hit: 2000000\n"
        "contains_miss: 2000000\n"
        "union: 5000000\n"
        "intersect: 2500000\n"
        "difference: 2500000\n"
    ),
    "compiler_ast": "compiler_ast checksum: 2390849568879\n",
    "compiler_emit": (
        "compiler_emit checksum: -4239430305840994758\n"
        "compiler_emit bytes: 263793\n"
    ),
    # The suite's shared binary_trees argument is 15 (benchmarks/args/).
    "binary_trees": (
        "stretch tree of depth 16 check: 6442483711\n"
        "32768 trees of depth 4 check: 12812288\n"
        "8192 trees of depth 6 check: 50585600\n"
        "2048 trees of depth 8 check: 201586688\n"
        "512 trees of depth 10 check: 805568000\n"
        "128 trees of depth 12 check: 3221487488\n"
        "32 trees of depth 14 check: 12885164000\n"
        "long lived tree of depth 15 check: 1610629119\n"
    ),
}
BENCH_RE = re.compile(
    r"^BENCH\s+.*(?:seconds=([0-9]+(?:\.[0-9]+)?)|microseconds=([0-9]+)|micros=([0-9]+))",
    re.M,
)
RESOURCE_TIMER = ["/usr/bin/time", "-l"]
INSTRUCTIONS_RE = re.compile(r"^\s*(\d+)\s+instructions retired", re.M)
PEAK_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.M)


@dataclass(frozen=True)
class ResourceUsage:
    instructions: int
    peak_rss_bytes: int


def last_match(pattern: re.Pattern[str], text: str) -> re.Match[str] | None:
    match = None
    for candidate in pattern.finditer(text):
        match = candidate
    return match


def run_once(
    name: str, command: list[str], *, resource_stats: bool = False
) -> tuple[float, ResourceUsage | None]:
    if resource_stats:
        command = [*RESOURCE_TIMER, *command]
    # Only capture rows with a small exact output contract; other rows can be large.
    expected_output = EXPECTED_OUTPUTS.get(name)
    proc = subprocess.run(
        command,
        stdout=subprocess.PIPE if expected_output is not None else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    actual_output = proc.stdout
    if name == "binary_trees":
        # Existing variants use tabs or spaces between the same exact fields.
        # Preserve line boundaries, order and every checksum digit.
        actual_output = re.sub(r"[ \t]+", " ", actual_output)
    if expected_output is not None and actual_output != expected_output:
        sys.stderr.write(
            f"{name} output mismatch: expected {expected_output!r}, "
            f"got {proc.stdout[:120]!r}\n"
        )
        raise SystemExit(125)

    match = last_match(BENCH_RE, proc.stderr)
    if match is None:
        sys.stderr.write("benchmark did not report a BENCH timing line\n")
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise SystemExit(125)

    seconds, microseconds, micros = match.groups()
    if seconds is not None:
        elapsed = float(seconds)
    elif microseconds is not None:
        elapsed = float(microseconds) / 1_000_000.0
    else:
        elapsed = float(micros) / 1_000_000.0

    if not resource_stats:
        return elapsed, None
    instructions = last_match(INSTRUCTIONS_RE, proc.stderr)
    peak_rss = last_match(PEAK_RSS_RE, proc.stderr)
    if instructions is None or peak_rss is None:
        sys.stderr.write(
            "resource stats need macOS /usr/bin/time -l to report "
            "instructions retired and maximum resident set size\n"
        )
        raise SystemExit(125)
    return elapsed, ResourceUsage(int(instructions.group(1)), int(peak_rss.group(1)))


def main(arguments: list[str]) -> None:
    resource_stats_path = None
    if arguments[:1] == ["--resource-stats"]:
        resource_stats_path = arguments[1]
        arguments = arguments[2:]
    warmups = int(arguments[0])
    runs = int(arguments[1])
    name = arguments[2]
    command = arguments[3:]

    for _ in range(warmups):
        run_once(name, command)

    samples = [
        run_once(name, command, resource_stats=resource_stats_path is not None)
        for _ in range(runs)
    ]
    if resource_stats_path is not None:
        # Retired instructions are nearly deterministic, so the minimum is the
        # steadiest sample; peak RSS reports the largest footprint observed.
        usages = [usage for _, usage in samples]
        instructions = min(usage.instructions for usage in usages)
        peak_rss_bytes = max(usage.peak_rss_bytes for usage in usages)
        with open(resource_stats_path, "w", encoding="utf-8") as stats:
            stats.write(f"instructions={instructions} peak_rss_bytes={peak_rss_bytes}\n")
    print(f"{min(seconds for seconds, _ in samples):.4f}")


if __name__ == "__main__":
    main(sys.argv[1:])
