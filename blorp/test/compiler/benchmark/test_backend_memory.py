#!/usr/bin/env python3
"""Contract tests for benchmarks/compiler_backend_memory."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[4]
SCRIPT = ROOT / "benchmarks" / "compiler_backend_memory"


def load_benchmark_module():
    loader = importlib.machinery.SourceFileLoader(
        "compiler_backend_memory_benchmark",
        str(SCRIPT),
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create benchmark module spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def request_json(action: str = "emit_core_c") -> dict[str, object]:
    return {
        "schema": 1,
        "domain": "compiler",
        "action": action,
        "payload": {
            "core": {
                "kind": "program",
                "decls": [],
                "foreign_includes": [],
            },
            "profile": False,
        },
    }


def fake_bridge_source() -> str:
    return """#!/usr/bin/env python3
import json
import os
import sys
import time

delay = float(os.environ.get("BLORP_FAKE_BRIDGE_DELAY", "0"))
if delay > 0:
    time.sleep(delay)

with open(sys.argv[1], encoding="utf-8") as request_file:
    request = json.load(request_file)

if request["action"] != "emit_core_c":
    raise SystemExit(2)

print(json.dumps({
    "schema": 1,
    "ok": True,
    "artifact": {
        "c_code": "/* captured replay */\\nint main(void) { return 0; }\\n",
        "link_flags": [],
        "include_dirs": [],
    },
}))
"""


def process_tree_bridge_source() -> str:
    return """#!/usr/bin/env python3
import os
import signal
import time
from pathlib import Path

started = Path(os.environ["BLORP_FAKE_BRIDGE_STARTED"])
survived = os.environ["BLORP_FAKE_BRIDGE_SURVIVED"]
survive_delay = os.environ.get("BLORP_FAKE_BRIDGE_SURVIVE_DELAY", "2")

def survive_sigterm(_signum, _frame):
    # Measure survival from cleanup, not from an earlier launch timestamp.
    time.sleep(float(survive_delay))
    Path(survived).write_text("survived", encoding="utf-8")

# Keep the descendant in the renderer's process group without giving the
# renderer's Python interpreter a Popen object that could own its shutdown.
child_pid = os.fork()
if child_pid == 0:
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, survive_sigterm)
    started.write_text("started", encoding="utf-8")
    time.sleep(5)
    os._exit(0)

Path(os.environ["BLORP_FAKE_BRIDGE_CHILD_PID"]).write_text(
    str(child_pid),
    encoding="utf-8",
)
while not started.exists():
    time.sleep(0.01)
if os.environ.get("BLORP_FAKE_BRIDGE_PARENT_EXIT") == "1":
    raise SystemExit(0)
time.sleep(5)
"""


@contextlib.contextmanager
def environment(name: str, value: str):
    previous = os.environ.get(name)
    os.environ[name] = value
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = previous


class CompilerBackendMemoryBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.benchmark = load_benchmark_module()

    def replay_args(
        self,
        request_path: Path,
        bridge_path: Path,
        timeout: float = 2.0,
    ) -> argparse.Namespace:
        return argparse.Namespace(
            request=str(request_path),
            bridge=str(bridge_path),
            timeout=timeout,
            allow_large_request=False,
            vmmap=False,
            json=True,
        )

    def assert_process_stopped(self, pid_path: Path) -> None:
        self.assertTrue(pid_path.exists())
        pid = int(pid_path.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            status_path = Path(f"/proc/{pid}/stat")
            try:
                status = status_path.read_text(encoding="utf-8")
            except OSError:
                status = ""
            closing_parenthesis = status.rfind(")")
            if closing_parenthesis >= 0:
                status_fields = status[closing_parenthesis + 1 :].split()
                # Containers without an init reaper can retain a killed
                # grandchild as a zombie. It exists, but cannot execute.
                if status_fields and status_fields[0] == "Z":
                    return

            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.01)
        self.fail(f"process {pid} is still running")

    def test_replay_reports_provenance_and_validates_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "fake_renderer"
            request_bytes = json.dumps(
                request_json(),
                separators=(",", ":"),
            ).encode("utf-8")
            bridge_source = fake_bridge_source()
            request_path.write_bytes(request_bytes)
            bridge_path.write_text(bridge_source, encoding="utf-8")
            bridge_path.chmod(0o755)
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = self.benchmark.run_benchmark(
                    self.replay_args(request_path, bridge_path)
                )

            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 0)
        self.assertTrue(result["verified"])
        self.assertFalse(result["timed_out"])
        self.assertEqual(
            result["request_sha256"],
            hashlib.sha256(request_bytes).hexdigest(),
        )
        self.assertEqual(
            result["bridge_sha256"],
            hashlib.sha256(bridge_source.encode("utf-8")).hexdigest(),
        )
        self.assertGreater(result["response_bytes"], 0)
        self.assertGreater(result["generated_c_bytes"], 0)

    def test_replay_timeout_stops_helper_and_reports_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "slow_renderer"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            output = io.StringIO()

            with environment("BLORP_FAKE_BRIDGE_DELAY", "2"):
                with contextlib.redirect_stdout(output):
                    exit_code = self.benchmark.run_benchmark(
                        self.replay_args(request_path, bridge_path, timeout=0.05)
                    )

            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 124)
        self.assertFalse(result["verified"])
        self.assertTrue(result["timed_out"])
        self.assertGreaterEqual(result["elapsed_seconds"], 0.05)

    def test_worker_error_stops_renderer_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            response_path = temp_dir / "response.json"
            stderr_path = temp_dir / "bridge.stderr"
            metrics_path = temp_dir / "metrics.json"
            bridge_path = temp_dir / "tree_renderer"
            started_path = temp_dir / "started"
            survived_path = temp_dir / "survived"
            child_pid_path = temp_dir / "child.pid"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(process_tree_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            def fail_sampler(
                _pid: int,
                _timeout_seconds: float,
            ) -> dict[str, object]:
                deadline = time.monotonic() + 1
                while not started_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(started_path.exists())
                raise RuntimeError("sampler failed")

            worker_args = [
                str(bridge_path),
                str(request_path),
                str(response_path),
                str(stderr_path),
                str(metrics_path),
                "2",
                "1",
            ]
            original_grace = self.benchmark.TERMINATE_GRACE_SECONDS
            self.benchmark.TERMINATE_GRACE_SECONDS = 0.05
            with environment("BLORP_FAKE_BRIDGE_STARTED", str(started_path)):
                try:
                    with environment(
                        "BLORP_FAKE_BRIDGE_SURVIVED",
                        str(survived_path),
                    ):
                        with environment(
                            "BLORP_FAKE_BRIDGE_CHILD_PID",
                            str(child_pid_path),
                        ):
                            with mock.patch.object(
                                self.benchmark,
                                "vmmap_metrics",
                                side_effect=fail_sampler,
                            ):
                                with self.assertRaisesRegex(
                                    RuntimeError,
                                    "sampler failed",
                                ):
                                    self.benchmark.measurement_worker(worker_args)
                finally:
                    self.benchmark.TERMINATE_GRACE_SECONDS = original_grace

            time.sleep(0.1)
            self.assertFalse(survived_path.exists())
            self.assert_process_stopped(child_pid_path)

    def test_sigterm_stops_renderer_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            response_path = temp_dir / "response.json"
            stderr_path = temp_dir / "bridge.stderr"
            metrics_path = temp_dir / "metrics.json"
            bridge_path = temp_dir / "tree_renderer"
            started_path = temp_dir / "started"
            survived_path = temp_dir / "survived"
            child_pid_path = temp_dir / "child.pid"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(process_tree_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            environment_values = {
                **os.environ,
                "BLORP_FAKE_BRIDGE_STARTED": str(started_path),
                "BLORP_FAKE_BRIDGE_SURVIVED": str(survived_path),
                "BLORP_FAKE_BRIDGE_CHILD_PID": str(child_pid_path),
            }
            worker = subprocess.Popen(
                [
                    os.fspath(SCRIPT),
                    self.benchmark.WORKER_FLAG,
                    str(bridge_path),
                    str(request_path),
                    str(response_path),
                    str(stderr_path),
                    str(metrics_path),
                    "5",
                    "0",
                ],
                env=environment_values,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + 1
            while not started_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(started_path.exists())

            worker.terminate()
            self.assertNotEqual(worker.wait(timeout=3), 0)
            self.assertFalse(survived_path.exists())
            self.assert_process_stopped(child_pid_path)

    def test_normal_renderer_exit_stops_surviving_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            response_path = temp_dir / "response.json"
            stderr_path = temp_dir / "bridge.stderr"
            metrics_path = temp_dir / "metrics.json"
            bridge_path = temp_dir / "tree_renderer"
            started_path = temp_dir / "started"
            survived_path = temp_dir / "survived"
            child_pid_path = temp_dir / "child.pid"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(process_tree_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            worker_args = [
                str(bridge_path),
                str(request_path),
                str(response_path),
                str(stderr_path),
                str(metrics_path),
                "2",
                "0",
            ]
            original_grace = self.benchmark.TERMINATE_GRACE_SECONDS
            self.benchmark.TERMINATE_GRACE_SECONDS = 0.05

            try:
                with environment("BLORP_FAKE_BRIDGE_STARTED", str(started_path)):
                    with environment(
                        "BLORP_FAKE_BRIDGE_SURVIVED",
                        str(survived_path),
                    ):
                        with environment(
                            "BLORP_FAKE_BRIDGE_CHILD_PID",
                            str(child_pid_path),
                        ):
                            with environment(
                                "BLORP_FAKE_BRIDGE_SURVIVE_DELAY",
                                "0.15",
                            ):
                                with environment(
                                    "BLORP_FAKE_BRIDGE_PARENT_EXIT",
                                    "1",
                                ):
                                    self.assertEqual(
                                        self.benchmark.measurement_worker(worker_args),
                                        0,
                                    )
            finally:
                self.benchmark.TERMINATE_GRACE_SECONDS = original_grace

            time.sleep(0.25)
            self.assertFalse(survived_path.exists())
            self.assert_process_stopped(child_pid_path)

    def test_controller_interrupt_stops_renderer_process_group(self) -> None:
        for interrupt in ("sigterm", "process_group_sigint"):
            with self.subTest(interrupt=interrupt):
                with tempfile.TemporaryDirectory() as temp_name:
                    temp_dir = Path(temp_name)
                    request_path = temp_dir / "request.json"
                    bridge_path = temp_dir / "tree_renderer"
                    started_path = temp_dir / "started"
                    survived_path = temp_dir / "survived"
                    child_pid_path = temp_dir / "child.pid"
                    request_path.write_text(
                        json.dumps(request_json()),
                        encoding="utf-8",
                    )
                    bridge_path.write_text(
                        process_tree_bridge_source(),
                        encoding="utf-8",
                    )
                    bridge_path.chmod(0o755)
                    environment_values = {
                        **os.environ,
                        "BLORP_FAKE_BRIDGE_STARTED": str(started_path),
                        "BLORP_FAKE_BRIDGE_SURVIVED": str(survived_path),
                        "BLORP_FAKE_BRIDGE_CHILD_PID": str(child_pid_path),
                    }
                    controller = subprocess.Popen(
                        [
                            os.fspath(SCRIPT),
                            str(request_path),
                            "--bridge",
                            str(bridge_path),
                            "--timeout",
                            "5",
                            "--json",
                        ],
                        env=environment_values,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=interrupt == "process_group_sigint",
                    )
                    deadline = time.monotonic() + 2
                    while (
                        not started_path.exists()
                        and time.monotonic() < deadline
                    ):
                        time.sleep(0.01)
                    self.assertTrue(started_path.exists())

                    if interrupt == "sigterm":
                        controller.terminate()
                    else:
                        os.killpg(controller.pid, signal.SIGINT)
                    self.assertNotEqual(controller.wait(timeout=5), 0)
                    self.assertFalse(survived_path.exists())
                    self.assert_process_stopped(child_pid_path)

    def test_vmmap_mode_omits_sampler_polluted_peak_rss(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            response_path = temp_dir / "response.json"
            stderr_path = temp_dir / "bridge.stderr"
            metrics_path = temp_dir / "metrics.json"
            bridge_path = temp_dir / "fake_renderer"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            worker_args = [
                str(bridge_path),
                str(request_path),
                str(response_path),
                str(stderr_path),
                str(metrics_path),
                "2",
                "1",
            ]

            with mock.patch.object(
                self.benchmark,
                "vmmap_metrics",
                return_value={"physical_footprint_bytes": 123},
            ):
                self.assertEqual(
                    self.benchmark.measurement_worker(worker_args),
                    0,
                )

            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
            self.assertEqual(metrics["physical_footprint_bytes"], 123)
            self.assertNotIn("peak_rss_bytes", metrics)

    def test_nonzero_renderer_exit_reports_failure_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "failing_renderer"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(
                "#!/bin/sh\nprintf 'renderer failed' >&2\nexit 7\n",
                encoding="utf-8",
            )
            bridge_path.chmod(0o755)
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                exit_code = self.benchmark.run_benchmark(
                    self.replay_args(request_path, bridge_path)
                )

            result = json.loads(output.getvalue())

        self.assertEqual(exit_code, 1)
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(result["error"], "renderer failed")
        self.assertFalse(result["verified"])

    def test_replay_rejects_non_emit_request(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "fake_renderer"
            request_path.write_text(
                json.dumps(request_json("typecheck_graph")),
                encoding="utf-8",
            )
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)

            with self.assertRaisesRegex(RuntimeError, "emit_core_c"):
                self.benchmark.run_benchmark(
                    self.replay_args(request_path, bridge_path)
                )

    def test_replay_requires_explicit_large_request_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "fake_renderer"
            request_path.write_text("not valid JSON", encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            original_threshold = self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES
            self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES = 1

            try:
                with self.assertRaisesRegex(RuntimeError, "external memory limit"):
                    self.benchmark.run_benchmark(
                        self.replay_args(request_path, bridge_path)
                    )
            finally:
                self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES = original_threshold

    def test_replay_allows_acknowledged_large_request(self) -> None:
        with tempfile.TemporaryDirectory() as temp_name:
            temp_dir = Path(temp_name)
            request_path = temp_dir / "request.json"
            bridge_path = temp_dir / "fake_renderer"
            request_path.write_text(json.dumps(request_json()), encoding="utf-8")
            bridge_path.write_text(fake_bridge_source(), encoding="utf-8")
            bridge_path.chmod(0o755)
            args = self.replay_args(request_path, bridge_path)
            args.allow_large_request = True
            output = io.StringIO()
            original_threshold = self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES
            self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES = 1

            try:
                with contextlib.redirect_stdout(output):
                    exit_code = self.benchmark.run_benchmark(args)
            finally:
                self.benchmark.MAX_UNCONFIRMED_REQUEST_BYTES = original_threshold

        self.assertEqual(exit_code, 0)
        self.assertTrue(json.loads(output.getvalue())["verified"])


if __name__ == "__main__":
    unittest.main()
