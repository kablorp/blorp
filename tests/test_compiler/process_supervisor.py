"""Bounded subprocess capture with process-tree cleanup for compiler fixtures."""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
import os
import signal
import subprocess
import sys
import threading
import time


PROCESS_TIMEOUT_EXIT = 124
CAPTURE_LIMIT_EXIT = 125
SUPERVISOR_ERROR_EXIT = 126
DEFAULT_CAPTURE_LIMIT_BYTES = 1024 * 1024
POLL_INTERVAL_SECONDS = 0.05
TERMINATION_GRACE_SECONDS = 1.0
LINUX_SET_CHILD_SUBREAPER = 36


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    output: str


def process_children() -> dict[int, list[int]]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid="],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=1,
        check=False,
    )
    if result.returncode != 0:
        raise OSError(f"ps exited with status {result.returncode}")
    children: dict[int, list[int]] = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2:
            continue
        pid, parent_pid = (int(field) for field in fields)
        children.setdefault(parent_pid, []).append(pid)
    return children


def descendant_pids(root_pid: int, children: dict[int, list[int]]) -> set[int]:
    descendants: set[int] = set()
    pending = list(children.get(root_pid, []))
    while pending:
        pid = pending.pop()
        if pid in descendants:
            continue
        descendants.add(pid)
        pending.extend(children.get(pid, []))
    return descendants


def enable_child_subreaper() -> bool:
    """Keep orphaned command descendants attributable on Linux.

    A process can leave its original process group with setsid(). Linux's
    subreaper facility makes those descendants children of this serial fixture
    runner when their immediate parent exits, closing the otherwise unavoidable
    process-enumeration race.
    """
    if not sys.platform.startswith("linux"):
        return False
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(LINUX_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return True


def owned_processes(
    root_pid: int,
    supervisor_pid: int,
    baseline_children: set[int],
    child_subreaper_enabled: bool,
) -> set[int]:
    children = process_children()
    owned = descendant_pids(root_pid, children)
    if child_subreaper_enabled:
        adopted = {
            pid
            for pid in children.get(supervisor_pid, [])
            if pid != root_pid
            and pid not in baseline_children
            and pid_is_running(pid)
        }
        owned.update(adopted)
        for pid in adopted:
            owned.update(descendant_pids(pid, children))
    return owned


def pid_is_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def reap_adopted_process(pid: int) -> bool:
    try:
        reaped_pid, _ = os.waitpid(pid, os.WNOHANG)
        return reaped_pid == pid
    except ChildProcessError:
        return False


def signal_processes(root_pid: int, descendants: set[int], signum: int) -> None:
    for pid in descendants:
        try:
            os.kill(pid, signum)
        except OSError:
            pass
    try:
        os.killpg(root_pid, signum)
    except OSError:
        pass


def terminate_processes(process: subprocess.Popen[bytes], descendants: set[int]) -> list[int]:
    signal_processes(process.pid, descendants, signal.SIGTERM)
    deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
    while time.monotonic() < deadline:
        active_descendants = {
            pid
            for pid in descendants
            if not reap_adopted_process(pid) and pid_is_running(pid)
        }
        if process.poll() is not None and not active_descendants:
            return []
        time.sleep(POLL_INTERVAL_SECONDS)

    signal_processes(process.pid, descendants, signal.SIGKILL)
    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    return [
        pid
        for pid in descendants
        if not reap_adopted_process(pid) and pid_is_running(pid)
    ]


def run_command(
    command: list[str],
    timeout: int,
    capture_limit: int = DEFAULT_CAPTURE_LIMIT_BYTES,
) -> CommandResult:
    supervisor_pid = os.getpid()
    try:
        child_subreaper_enabled = enable_child_subreaper()
        baseline_children = (
            {
                pid
                for pid in process_children().get(supervisor_pid, [])
                if pid_is_running(pid)
            }
            if child_subreaper_enabled
            else set()
        )
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return CommandResult(SUPERVISOR_ERROR_EXIT, f"could not start command: {error}")

    captured = bytearray()
    capture_exceeded = threading.Event()

    def drain_output() -> None:
        assert process.stdout is not None
        while True:
            chunk = process.stdout.read(65536)
            if not chunk:
                return
            remaining = capture_limit - len(captured)
            if remaining > 0:
                captured.extend(chunk[:remaining])
            if len(chunk) > remaining:
                capture_exceeded.set()

    output_thread = threading.Thread(target=drain_output, daemon=True)
    output_thread.start()
    descendants: set[int] = set()
    deadline = None if timeout == 0 else time.monotonic() + timeout
    failure_code: int | None = None
    failure_detail = ""

    while process.poll() is None:
        try:
            descendants.update(
                owned_processes(
                    process.pid,
                    supervisor_pid,
                    baseline_children,
                    child_subreaper_enabled,
                )
            )
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            failure_code = SUPERVISOR_ERROR_EXIT
            failure_detail = f"process supervision failed: {error}"
            break
        if capture_exceeded.is_set():
            failure_code = CAPTURE_LIMIT_EXIT
            failure_detail = f"capture limit exceeded ({capture_limit} bytes)"
            break
        if deadline is not None and time.monotonic() >= deadline:
            failure_code = PROCESS_TIMEOUT_EXIT
            failure_detail = f"timed out after {timeout}s"
            break
        time.sleep(POLL_INTERVAL_SECONDS)

    try:
        descendants.update(
            owned_processes(
                process.pid,
                supervisor_pid,
                baseline_children,
                child_subreaper_enabled,
            )
        )
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass

    descendants = {
        pid
        for pid in descendants
        if not reap_adopted_process(pid) and pid_is_running(pid)
    }
    if descendants and failure_code is None:
        failure_code = SUPERVISOR_ERROR_EXIT
        failure_detail = "command left descendant processes running"
    survivors = (
        terminate_processes(process, descendants)
        if descendants or failure_code
        else []
    )
    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        if failure_code is None:
            failure_code = SUPERVISOR_ERROR_EXIT
            failure_detail = "command did not exit after supervision"

    output_thread.join(timeout=TERMINATION_GRACE_SECONDS)
    if output_thread.is_alive() and failure_code is None:
        failure_code = SUPERVISOR_ERROR_EXIT
        failure_detail = "captured output remained open after command exit"
        survivors = terminate_processes(process, descendants)
        output_thread.join(timeout=TERMINATION_GRACE_SECONDS)
    if capture_exceeded.is_set() and failure_code is None:
        failure_code = CAPTURE_LIMIT_EXIT
        failure_detail = f"capture limit exceeded ({capture_limit} bytes)"
    if survivors:
        failure_code = SUPERVISOR_ERROR_EXIT
        failure_detail = "could not terminate descendant processes: " + ", ".join(
            str(pid) for pid in survivors
        )

    output = bytes(captured).decode("utf-8", errors="replace")
    if failure_detail:
        output = f"{failure_detail}\n{output}"
    return CommandResult(
        failure_code if failure_code is not None else process.returncode,
        output,
    )
