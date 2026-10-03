#!/usr/bin/env python3
"""Run benchmark samples and read the in-process BENCH timing marker."""

from __future__ import annotations

import re
import subprocess
import sys


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
}
BENCH_RE = re.compile(
    r"^BENCH\s+.*(?:seconds=([0-9]+(?:\.[0-9]+)?)|microseconds=([0-9]+)|micros=([0-9]+))",
    re.M,
)


def run_once(name: str, command: list[str]) -> float:
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

    if expected_output is not None and proc.stdout != expected_output:
        sys.stderr.write(
            f"{name} output mismatch: expected {expected_output!r}, "
            f"got {proc.stdout[:120]!r}\n"
        )
        raise SystemExit(125)

    match = None
    for candidate in BENCH_RE.finditer(proc.stderr):
        match = candidate
    if match is None:
        sys.stderr.write("benchmark did not report a BENCH timing line\n")
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise SystemExit(125)

    seconds, microseconds, micros = match.groups()
    if seconds is not None:
        return float(seconds)
    if microseconds is not None:
        return float(microseconds) / 1_000_000.0
    return float(micros) / 1_000_000.0


def main(arguments: list[str]) -> None:
    warmups = int(arguments[0])
    runs = int(arguments[1])
    name = arguments[2]
    command = arguments[3:]

    for _ in range(warmups):
        run_once(name, command)

    samples = [run_once(name, command) for _ in range(runs)]
    print(f"{min(samples):.4f}")


if __name__ == "__main__":
    main(sys.argv[1:])
