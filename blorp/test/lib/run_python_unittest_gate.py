#!/usr/bin/env python3
"""Run Python unittest files as one counted scripts/test gate component.

Each file runs in its own supervised child process so a hang hits the gate
timeout instead of stalling the gate. Every test method counts toward the
structured BLORP_GATE_RESULT line; skipped tests, errors, unexpected
successes, import failures and timeouts count as failures, because a gate
test that silently skips is not being run.
"""

from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import sys
import unittest

from process_supervisor import CAPTURE_LIMIT_EXIT, PROCESS_TIMEOUT_EXIT, run_command


CHILD_RESULT_PREFIX = "PYTHON_UNITTEST_RESULT"


def run_child(path: Path) -> int:
    spec = importlib.util.spec_from_file_location(f"gate_test_{path.stem}", path)
    if spec is None or spec.loader is None:
        print(f"FAIL: {path}: cannot load module")
        print(f"{CHILD_RESULT_PREFIX} tests=1 failed=1")
        return 1
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as error:  # noqa: BLE001 - any import failure fails the file
        print(f"FAIL: {path}: import failed: {error!r}")
        print(f"{CHILD_RESULT_PREFIX} tests=1 failed=1")
        return 1

    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(suite)
    failed_tests = (
        [test for test, _ in result.failures]
        + [test for test, _ in result.errors]
        + [test for test, _ in result.skipped]
        + list(result.unexpectedSuccesses)
    )
    tests = result.testsRun
    if tests == 0:
        print(f"FAIL: {path}: no tests found")
        print(f"{CHILD_RESULT_PREFIX} tests=1 failed=1")
        return 1
    for test in failed_tests:
        print(f"FAIL: {path}::{test.id()}")
    failed = min(len(failed_tests), tests)
    print(f"{CHILD_RESULT_PREFIX} tests={tests} failed={failed}")
    return 0 if failed == 0 else 1


def parse_child_result(output: str) -> tuple[int, int] | None:
    for line in reversed(output.splitlines()):
        fields = line.split()
        if len(fields) != 3 or fields[0] != CHILD_RESULT_PREFIX:
            continue
        try:
            tests = int(fields[1].removeprefix("tests="))
            failed = int(fields[2].removeprefix("failed="))
        except ValueError:
            return None
        if 0 <= failed <= tests:
            return tests, failed
        return None
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate-name", required=True)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("tests", nargs="+", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.child:
        return run_child(args.tests[0])

    passed = 0
    failed = 0
    for path in args.tests:
        if not path.is_file():
            print(f"FAIL: {path}: unittest file does not exist")
            failed += 1
            continue
        result = run_command(
            [sys.executable, str(Path(__file__).resolve()), "--gate-name", args.gate_name,
             "--child", str(path)],
            args.timeout,
        )
        print(result.output, end="" if result.output.endswith("\n") else "\n")
        counts = parse_child_result(result.output)
        if result.returncode == PROCESS_TIMEOUT_EXIT:
            print(f"FAIL: {path}: timed out after {args.timeout}s")
            failed += 1
        elif result.returncode == CAPTURE_LIMIT_EXIT:
            print(f"FAIL: {path}: output exceeded the capture limit")
            failed += 1
        elif counts is None:
            print(f"FAIL: {path}: exited {result.returncode} without a result")
            failed += 1
        else:
            tests, file_failed = counts
            if result.returncode != 0 and file_failed == 0:
                print(f"FAIL: {path}: exited {result.returncode} after passing")
                file_failed = 1
            passed += tests - file_failed
            failed += file_failed

    status = "PASS" if failed == 0 else "FAIL"
    print(
        f"BLORP_GATE_RESULT gate={args.gate_name} status={status} "
        f"passed={passed} failed={failed} tests={passed + failed}"
    )
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
