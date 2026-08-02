#!/usr/bin/env python3
"""Build the standalone typecheck worker used by compiler benchmarks."""

from __future__ import annotations

import os
import platform
import shlex
import subprocess
from pathlib import Path


TYPECHECK_WORKER_ENV = "BLORP_TYPECHECK_BENCHMARK_WORKER"
WORKER_SOURCE = Path("compiler/blorp/benchmarks/compiler_typecheck_worker.brp")
WORKER_MAIN_SYMBOL = "__blorp_typecheck_benchmark_worker_main"
WORKER_STACK_SIZE_BYTES = 256 * 1024 * 1024
COMMON_CC_FLAGS = ("-O0", "-fwrapv", "-pipe", "-w")


def _worker_wrapper_source() -> str:
    return f"""#include <pthread.h>
#include <stddef.h>

extern int {WORKER_MAIN_SYMBOL}(int argc, char **argv);

typedef struct {{
    int argc;
    char **argv;
    int result;
}} blorp_typecheck_worker_main_args;

static void *blorp_typecheck_worker_main_entry(void *raw) {{
    blorp_typecheck_worker_main_args *args =
        (blorp_typecheck_worker_main_args *)raw;
    args->result = {WORKER_MAIN_SYMBOL}(args->argc, args->argv);
    return NULL;
}}

int main(int argc, char **argv) {{
    pthread_attr_t attr;
    pthread_t thread;
    blorp_typecheck_worker_main_args args = {{ argc, argv, 1 }};

    if (pthread_attr_init(&attr) != 0) {{
        return {WORKER_MAIN_SYMBOL}(argc, argv);
    }}
    if (pthread_attr_setstacksize(&attr, (size_t){WORKER_STACK_SIZE_BYTES}) != 0) {{
        pthread_attr_destroy(&attr);
        return {WORKER_MAIN_SYMBOL}(argc, argv);
    }}
    if (pthread_create(&thread, &attr, blorp_typecheck_worker_main_entry, &args) != 0) {{
        pthread_attr_destroy(&attr);
        return {WORKER_MAIN_SYMBOL}(argc, argv);
    }}

    pthread_attr_destroy(&attr);
    if (pthread_join(thread, NULL) != 0) {{
        return 1;
    }}
    return args.result;
}}
"""


def _run(command: list[str], root: Path, description: str) -> None:
    try:
        completed = subprocess.run(
            command,
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except OSError as error:
        raise RuntimeError(f"{description} failed to start: {error}") from error
    if completed.returncode == 0:
        return
    detail = (completed.stderr.strip() or completed.stdout.strip() or "no output")
    raise RuntimeError(f"{description} failed: {detail}")


def _explicit_worker(explicit: str | None) -> Path | None:
    candidate = explicit or os.environ.get(TYPECHECK_WORKER_ENV)
    if not candidate:
        return None
    path = Path(candidate).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"typecheck benchmark worker is not executable: {path}")
    return path


def prepare_typecheck_worker(
    root: Path,
    out_dir: Path,
    explicit: str | None,
) -> Path:
    """Resolve an override or build a disposable benchmark worker."""
    selected = _explicit_worker(explicit)
    if selected is not None:
        return selected

    compiler = root / "blorp"
    source = root / WORKER_SOURCE
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        raise RuntimeError("./blorp is missing; run `make` before this benchmark")
    if not source.is_file():
        raise RuntimeError(f"typecheck benchmark worker source is missing: {source}")

    out_dir.mkdir(parents=True, exist_ok=True)
    c_path = out_dir / "compiler_typecheck_worker.c"
    object_path = out_dir / "compiler_typecheck_worker.o"
    wrapper_path = out_dir / "compiler_typecheck_worker_main.c"
    worker_path = out_dir / "compiler_typecheck_worker"

    _run(
        [str(compiler), "compile", "--no-format", "-o", str(c_path), str(source)],
        root,
        "compiling the typecheck benchmark worker",
    )
    wrapper_path.write_text(_worker_wrapper_source(), encoding="utf-8")

    cc = shlex.split(os.environ.get("CC", "cc"))
    if not cc:
        raise RuntimeError("CC must name a C compiler")
    _run(
        [
            *cc,
            *COMMON_CC_FLAGS,
            f"-Dmain={WORKER_MAIN_SYMBOL}",
            "-c",
            str(c_path),
            "-o",
            str(object_path),
        ],
        root,
        "compiling the typecheck benchmark worker object",
    )
    stack_link_args = (
        ["-Wl,-stack_size,0x4000000"] if platform.system() == "Darwin" else []
    )
    _run(
        [
            *cc,
            *COMMON_CC_FLAGS,
            str(object_path),
            str(wrapper_path),
            *stack_link_args,
            "-lm",
            "-lpthread",
            "-o",
            str(worker_path),
        ],
        root,
        "linking the typecheck benchmark worker",
    )
    if not worker_path.is_file() or not os.access(worker_path, os.X_OK):
        raise RuntimeError(f"typecheck benchmark worker was not produced: {worker_path}")
    return worker_path
