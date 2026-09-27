#!/usr/bin/env python3
"""Build isolated Blorp compiler workers used only by diagnostic benchmarks."""

from __future__ import annotations

import os
import platform
import shlex
import subprocess
from pathlib import Path
from typing import Literal


WORKER_STACK_SIZE_BYTES = 256 * 1024 * 1024
COMMON_CC_FLAGS = ("-O0", "-fwrapv", "-pipe", "-w")


def _worker_wrapper_source(main_symbol: str, worker_name: str) -> str:
    c_name = worker_name.replace("-", "_")
    return f"""#include <pthread.h>
#include <stddef.h>

extern int {main_symbol}(int argc, char **argv);

typedef struct {{
    int argc;
    char **argv;
    int result;
}} {c_name}_main_args;

static void *{c_name}_main_entry(void *raw) {{
    {c_name}_main_args *args = ({c_name}_main_args *)raw;
    args->result = {main_symbol}(args->argc, args->argv);
    return NULL;
}}

int main(int argc, char **argv) {{
    pthread_attr_t attr;
    pthread_t thread;
    {c_name}_main_args args = {{ argc, argv, 1 }};

    if (pthread_attr_init(&attr) != 0) {{
        return {main_symbol}(argc, argv);
    }}
    if (pthread_attr_setstacksize(&attr, (size_t){WORKER_STACK_SIZE_BYTES}) != 0) {{
        pthread_attr_destroy(&attr);
        return {main_symbol}(argc, argv);
    }}
    if (pthread_create(&thread, &attr, {c_name}_main_entry, &args) != 0) {{
        pthread_attr_destroy(&attr);
        return {main_symbol}(argc, argv);
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
    detail = completed.stderr.strip() or completed.stdout.strip() or "no output"
    raise RuntimeError(f"{description} failed: {detail}")


def _explicit_worker(env_name: str, explicit: str | None) -> Path | None:
    candidate = explicit or os.environ.get(env_name)
    if not candidate:
        return None
    path = Path(candidate).expanduser().resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(f"compiler benchmark worker is not executable: {path}")
    return path


def _link_command(
    cc: list[str],
    root: Path,
    object_path: Path,
    wrapper_path: Path,
    worker_path: Path,
    link_sources: tuple[Path, ...] = (),
) -> list[str]:
    stack_link_args = (
        ["-Wl,-stack_size,0x4000000"] if platform.system() == "Darwin" else []
    )
    return [
        *cc,
        *COMMON_CC_FLAGS,
        str(object_path),
        str(wrapper_path),
        *(str((root / path).resolve()) for path in link_sources),
        *stack_link_args,
        "-lm",
        "-lpthread",
        "-o",
        str(worker_path),
    ]


def _compiler_command(
    compiler: Path,
    c_path: Path,
    source: Path,
    *,
    debug_profile: bool = False,
    profile_functions: tuple[str, ...] = (),
    profile_mode: Literal["exact", "calls"] = "exact",
) -> list[str]:
    if profile_mode not in ("exact", "calls"):
        raise ValueError("profile_mode must be exact or calls")
    if not debug_profile and (profile_functions or profile_mode != "exact"):
        raise ValueError("profile selection and mode require debug_profile")
    command = [str(compiler), "compile", "--no-format"]
    if debug_profile:
        command.append("--debug")
        if profile_mode == "exact":
            command.append("--profile")
        else:
            command.extend(("--profile-mode", "calls"))
        for selector in profile_functions:
            command.extend(("--profile-function", selector))
    command.extend(("-o", str(c_path), str(source)))
    return command


def prepare_benchmark_worker(
    root: Path,
    out_dir: Path,
    explicit: str | None,
    *,
    env_name: str,
    source_path: Path,
    worker_name: str,
    main_symbol: str,
    include_dirs: tuple[Path, ...] = (),
    link_sources: tuple[Path, ...] = (),
    debug_profile: bool = False,
    profile_functions: tuple[str, ...] = (),
    profile_mode: Literal["exact", "calls"] = "exact",
) -> Path:
    """Resolve an override or build one disposable benchmark worker."""
    selected = _explicit_worker(env_name, explicit)
    if selected is not None:
        return selected

    compiler = root / "bin" / "blorp"
    source = root / source_path
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        raise RuntimeError("bin/blorp is missing; run `make` before this benchmark")
    if not source.is_file():
        raise RuntimeError(f"compiler benchmark worker source is missing: {source}")

    out_dir.mkdir(parents=True, exist_ok=True)
    c_path = out_dir / f"{worker_name}.c"
    object_path = out_dir / f"{worker_name}.o"
    wrapper_path = out_dir / f"{worker_name}_main.c"
    worker_path = out_dir / worker_name

    compiler_arguments = _compiler_command(
        compiler,
        c_path,
        source,
        debug_profile=debug_profile,
        profile_functions=profile_functions,
        profile_mode=profile_mode,
    )
    _run(
        compiler_arguments,
        root,
        f"compiling the {worker_name} source",
    )
    wrapper_path.write_text(
        _worker_wrapper_source(main_symbol, worker_name),
        encoding="utf-8",
    )

    cc = shlex.split(os.environ.get("CC", "cc"))
    if not cc:
        raise RuntimeError("CC must name a C compiler")
    include_arguments = [
        f"-I{(root / include_dir).resolve()}"
        for include_dir in include_dirs
    ]
    _run(
        [
            *cc,
            *COMMON_CC_FLAGS,
            *include_arguments,
            f"-Dmain={main_symbol}",
            "-c",
            str(c_path),
            "-o",
            str(object_path),
        ],
        root,
        f"compiling the {worker_name} object",
    )
    _run(
        _link_command(cc, root, object_path, wrapper_path, worker_path, link_sources),
        root,
        f"linking the {worker_name}",
    )
    if not worker_path.is_file() or not os.access(worker_path, os.X_OK):
        raise RuntimeError(f"compiler benchmark worker was not produced: {worker_path}")
    return worker_path
