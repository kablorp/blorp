"""Build-free regression checks for the portable build-lock path."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[3]
WRAPPER = ROOT / "scripts" / "with-build-lock"


class BuildLockTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="blorp-build-lock-test-")
        self.addCleanup(self.temporary_directory.cleanup)
        self.base = Path(self.temporary_directory.name)
        tool_directory = self.base / "tools"
        tool_directory.mkdir()
        # Keep flock out of PATH so this exercises the portable branch on Linux too.
        for name in ("awk", "cat", "cksum", "dirname", "mkdir", "python3", "rm", "rmdir", "sleep"):
            executable = shutil.which(name)
            if executable is None:
                self.fail(f"required test tool is missing: {name}")
            (tool_directory / name).symlink_to(executable)
        self.environment = os.environ.copy()
        self.environment.update(
            PATH=str(tool_directory),
            BLORP_BUILD_LOCK_BASE=str(self.base / "build-locks"),
            BLORP_COMPILER_CONTENTION_LOCK_BASE=str(self.base / "contention"),
            BLORP_COMPILER_CONTENTION_ALLOW_TEST_OVERRIDE="1",
        )

    def run_locked(self, *command, timeout=5):
        return subprocess.run(
            [str(WRAPPER), *command],
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def start_locked(self, *command):
        process = subprocess.Popen(
            [str(WRAPPER), *command],
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        return process

    def wait_for_file(self, path):
        deadline = time.monotonic() + 3
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(path.exists(), f"command did not create {path}")

    def legacy_lock_directory(self):
        lock_key = subprocess.check_output(
            ["cksum"], input=str(ROOT).encode(), env=self.environment
        ).split()[0].decode()
        return Path(self.environment["BLORP_BUILD_LOCK_BASE"]) / f"{lock_key}.lock.d"

    def test_abandoned_directory_does_not_block(self):
        abandoned_directory = self.legacy_lock_directory()
        abandoned_directory.mkdir(parents=True)
        marker = self.base / "ran"
        result = self.run_locked(
            sys.executable,
            "-c",
            "import pathlib, sys; pathlib.Path(sys.argv[1]).touch()",
            str(marker),
            timeout=2,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(marker.exists())
        self.assertTrue(abandoned_directory.exists())

    def test_stale_directory_is_not_deleted(self):
        stale_directory = self.legacy_lock_directory()
        stale_directory.mkdir(parents=True)
        owner_file = stale_directory / "owner.pid"
        owner_file.write_text("99999999\n")
        result = self.run_locked(sys.executable, "-c", "pass", timeout=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(owner_file.read_text(), "99999999\n")

    def test_contenders_run_one_at_a_time(self):
        events = self.base / "events"
        entered = self.base / "entered"
        first = self.start_locked(
            sys.executable,
            "-c",
            "import pathlib, sys, time; "
            "pathlib.Path(sys.argv[2]).touch(); "
            "with_open = pathlib.Path(sys.argv[1]); "
            "with_open.open('a').write('first entered\\n'); "
            "time.sleep(0.4); "
            "with_open.open('a').write('first exited\\n')",
            str(events),
            str(entered),
        )
        self.wait_for_file(entered)
        second = self.run_locked(
            sys.executable,
            "-c",
            "import pathlib, sys; pathlib.Path(sys.argv[1]).open('a').write('second entered\\n')",
            str(events),
        )
        _, first_stderr = first.communicate(timeout=5)
        self.assertEqual(first.returncode, 0, first_stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(
            events.read_text().splitlines(),
            ["first entered", "first exited", "second entered"],
        )

    def test_killed_owner_releases_lock(self):
        entered = self.base / "entered"
        owner = self.start_locked(
            sys.executable,
            "-c",
            "import os, pathlib, signal, sys; "
            "pathlib.Path(sys.argv[1]).touch(); "
            "os.kill(os.getpid(), signal.SIGKILL)",
            str(entered),
        )
        self.wait_for_file(entered)
        owner.communicate(timeout=5)
        self.assertEqual(owner.returncode, -9)
        recovered = self.run_locked(sys.executable, "-c", "pass", timeout=2)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)

    def test_command_status_and_signal_propagate(self):
        failure = self.run_locked(sys.executable, "-c", "import sys; sys.exit(37)")
        self.assertEqual(failure.returncode, 37, failure.stderr)
        terminated = self.run_locked(
            sys.executable,
            "-c",
            "import os, signal; os.kill(os.getpid(), signal.SIGTERM)",
        )
        self.assertEqual(terminated.returncode, -15, terminated.stderr)


if __name__ == "__main__":
    unittest.main()
