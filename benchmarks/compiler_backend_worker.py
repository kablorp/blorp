#!/usr/bin/env python3
"""Build the standalone backend worker used by compiler benchmarks."""

from __future__ import annotations

from pathlib import Path

from compiler_benchmark_worker import prepare_benchmark_worker


BACKEND_WORKER_ENV = "BLORP_BACKEND_BENCHMARK_WORKER"
BACKEND_COUNTER_WORKER_ENV = "BLORP_BACKEND_COUNTER_BENCHMARK_WORKER"
WORKER_SOURCE = Path("blorp/benchmark/compiler/compiler_backend_worker.brp")
WORKER_NAME = "compiler_backend_worker"
WORKER_MAIN_SYMBOL = "__blorp_backend_benchmark_worker_main"


def prepare_backend_worker(
    root: Path,
    out_dir: Path,
    explicit: str | None,
    *,
    debug_profile: bool = False,
) -> Path:
    worker_options = {
        "env_name": (
            BACKEND_COUNTER_WORKER_ENV if debug_profile else BACKEND_WORKER_ENV
        ),
        "source_path": WORKER_SOURCE,
        "worker_name": WORKER_NAME,
        "main_symbol": WORKER_MAIN_SYMBOL,
    }
    if debug_profile:
        worker_options["debug_profile"] = True
    return prepare_benchmark_worker(root, out_dir, explicit, **worker_options)
