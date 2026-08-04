#!/usr/bin/env python3
"""Build the standalone typecheck worker used by compiler benchmarks."""

from __future__ import annotations

from pathlib import Path

from compiler_benchmark_worker import prepare_benchmark_worker


TYPECHECK_WORKER_ENV = "BLORP_TYPECHECK_BENCHMARK_WORKER"
WORKER_SOURCE = Path("compiler/blorp/benchmarks/compiler_typecheck_worker.brp")
WORKER_NAME = "compiler_typecheck_worker"
WORKER_MAIN_SYMBOL = "__blorp_typecheck_benchmark_worker_main"
# Generated typecheck C includes the graph-owned allocation identity helper.
WORKER_INCLUDE_DIRS = (
    Path("compiler/blorp/src/stage_06_typecheck/graph"),
)


def prepare_typecheck_worker(
    root: Path,
    out_dir: Path,
    explicit: str | None,
) -> Path:
    return prepare_benchmark_worker(
        root,
        out_dir,
        explicit,
        env_name=TYPECHECK_WORKER_ENV,
        source_path=WORKER_SOURCE,
        worker_name=WORKER_NAME,
        main_symbol=WORKER_MAIN_SYMBOL,
        include_dirs=WORKER_INCLUDE_DIRS,
    )
