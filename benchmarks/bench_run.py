#!/usr/bin/env python3
"""Run benchmark samples and read the in-process BENCH timing marker."""

from __future__ import annotations

import re
import subprocess
import sys


FIB_EXPECTED_OUTPUT = "Fib(40) = 102334155\n"
BENCH_RE = re.compile(
    r"^BENCH\s+.*(?:seconds=([0-9]+(?:\.[0-9]+)?)|microseconds=([0-9]+)|micros=([0-9]+))",
    re.M,
)


def run_once(name: str, command: list[str]) -> float:
    # Most rows can generate large output, so only capture the fib row's one-line oracle.
    proc = subprocess.run(
        command,
        stdout=subprocess.PIPE if name == "fib" else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    if name == "fib" and proc.stdout != FIB_EXPECTED_OUTPUT:
        sys.stderr.write(
            f"fib output mismatch: expected {FIB_EXPECTED_OUTPUT!r}, "
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
