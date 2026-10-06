#!/usr/bin/env python3
"""Process-lifetime regressions for the public LSP fixture client."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import signal
import sys
import tempfile
import time
import unittest


RUNNER_PATH = pathlib.Path(__file__).with_name("run_lsp_fixtures.py")
RUNNER_SPEC = importlib.util.spec_from_file_location("run_lsp_fixtures", RUNNER_PATH)
if RUNNER_SPEC is None or RUNNER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {RUNNER_PATH}")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
sys.modules[RUNNER_SPEC.name] = RUNNER
RUNNER_SPEC.loader.exec_module(RUNNER)


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class LspFixtureProcessTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "process-group cleanup is POSIX-only")
    def test_failed_shutdown_kills_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="blorp-lsp-process-test.") as temp:
            temp_path = pathlib.Path(temp)
            child_pid_path = temp_path / "child.pid"
            fake_blorp = temp_path / "fake-blorp"
            fake_blorp.write_text(
                """#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)",
])
with open(os.environ["BLORP_LSP_TEST_CHILD_PID"], "w", encoding="utf-8") as handle:
    handle.write(str(child.pid))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(60)
""",
                encoding="utf-8",
            )
            fake_blorp.chmod(0o755)

            previous_pid_path = os.environ.get("BLORP_LSP_TEST_CHILD_PID")
            os.environ["BLORP_LSP_TEST_CHILD_PID"] = str(child_pid_path)
            client = None
            child_pid = None
            try:
                client = RUNNER.LspClient(str(fake_blorp), temp_path)
                deadline = time.monotonic() + 2.0
                while not child_pid_path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(child_pid_path.exists(), "fake host did not start")
                child_pid = int(child_pid_path.read_text(encoding="utf-8"))

                def fail_shutdown(*_args: object, **_kwargs: object) -> object:
                    raise RUNNER.LspError("forced shutdown failure")

                client.request = fail_shutdown
                client.close()

                deadline = time.monotonic() + 2.0
                while process_exists(child_pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(
                    process_exists(child_pid),
                    "LSP child survived fixture cleanup",
                )
            finally:
                if previous_pid_path is None:
                    os.environ.pop("BLORP_LSP_TEST_CHILD_PID", None)
                else:
                    os.environ["BLORP_LSP_TEST_CHILD_PID"] = previous_pid_path
                if client is not None and client.proc.poll() is None:
                    client.proc.kill()
                    client.proc.wait(timeout=2.0)
                if child_pid is not None and process_exists(child_pid):
                    os.kill(child_pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
