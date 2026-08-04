#!/usr/bin/env python3
"""Contract tests for scripts/test-blorp-test-session-fast."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import hashlib
import io
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "test-blorp-test-session-fast"


def load_fast_loop_module():
    loader = importlib.machinery.SourceFileLoader("blorp_test_session_fast", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create fast-loop module spec")
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


class BlorpTestSessionFastLoopTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fast_loop = load_fast_loop_module()

    def run_verified_mock_case(
        self,
        case,
        supervision,
        stdin,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            runtime = root / "runtime.c"
            manifest = root / self.fast_loop.EMBEDDED_INPUT_MANIFEST
            build_manifest = root / self.fast_loop.BUILD_INPUT_MANIFEST
            compiler_bytes = b"compiler"
            runtime_bytes = b"runtime"
            compiler.write_bytes(compiler_bytes)
            compiler.chmod(0o755)
            runtime.write_bytes(runtime_bytes)
            manifest.parent.mkdir(parents=True)
            input_record = f"{hashlib.sha256(runtime_bytes).hexdigest()}  runtime.c\n"
            build_manifest.write_text(input_record, encoding="utf-8")
            manifest.write_text(
                (
                    "blorp-sha256 "
                    + hashlib.sha256(compiler_bytes).hexdigest()
                    + "\n"
                    + input_record
                ),
                encoding="utf-8",
            )
            process = mock.Mock(returncode=0, stdin=stdin)
            captured_stderr = mock.Mock()
            captured_stderr.buffer = io.BytesIO()

            with mock.patch.object(
                self.fast_loop,
                "project_root",
                return_value=root,
            ), mock.patch.object(
                self.fast_loop,
                "process_rows",
                return_value={},
            ), mock.patch.object(
                self.fast_loop.subprocess,
                "Popen",
                return_value=process,
            ), mock.patch.object(
                self.fast_loop,
                "supervise_process",
                return_value=supervision,
            ), mock.patch.object(
                sys,
                "stdout",
                new=io.StringIO(),
            ), mock.patch.object(
                sys,
                "stderr",
                new=captured_stderr,
            ):
                status = self.fast_loop.run_case("contract", case, 1)

            return status, process

    def wait_for_detached_child_after_leader_exit(
        self,
        process: subprocess.Popen[bytes],
        child_pid: int,
    ) -> bool:
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            child_row = self.fast_loop.process_rows().get(child_pid)
            if (
                self.fast_loop.process_has_exited_unreaped(process)
                and child_row is not None
                and child_row.parent_process_id != process.pid
                and child_row.process_group_id != process.pid
            ):
                return True
            time.sleep(0.01)
        return False

    def test_case_environment_removes_blorp_overrides(self) -> None:
        environment = self.fast_loop.case_environment(
            {
                "PATH": "/bin",
                "HOME": "/tmp/home",
                "BLORP_LEAK_CHECK": "1",
                "BLORP_TIMEOUT": "999",
                self.fast_loop.LOCK_HELD_ENV: "1",
            }
        )

        self.assertEqual(environment["PATH"], "/bin")
        self.assertEqual(environment["HOME"], "/tmp/home")
        self.assertFalse(any(key.startswith("BLORP_") for key in environment))

    def test_registered_case_source_inputs_exist(self) -> None:
        for name, case in self.fast_loop.CASES.items():
            with self.subTest(case=name):
                self.assertTrue(case.source_paths)
                for path in case.source_paths:
                    self.assertTrue((ROOT / path).is_file(), path)

    def test_changed_embedded_input_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.c"
            manifest = root / "embedded-inputs.sha256"
            runtime.write_bytes(b"changed runtime")
            recorded_hash = hashlib.sha256(b"built runtime").hexdigest()
            manifest.write_text(
                "blorp-sha256 " + ("0" * 64) + "\n"
                + f"{recorded_hash}  runtime.c\n",
                encoding="utf-8",
            )

            stale = self.fast_loop.stale_embedded_inputs(
                root,
                manifest,
                ("runtime.c",),
            )

            self.assertEqual(stale, ["runtime.c"])

    def test_unchanged_embedded_input_is_fresh(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.c"
            manifest = root / "embedded-inputs.sha256"
            runtime_bytes = b"runtime"
            runtime.write_bytes(runtime_bytes)
            recorded_hash = hashlib.sha256(runtime_bytes).hexdigest()
            manifest.write_text(
                "blorp-sha256 " + ("0" * 64) + "\n"
                + f"{recorded_hash}  runtime.c\n",
                encoding="utf-8",
            )

            stale = self.fast_loop.stale_embedded_inputs(
                root,
                manifest,
                ("runtime.c",),
            )

            self.assertEqual(stale, [])

    def test_missing_embedded_input_fingerprint_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.c"
            manifest = root / "embedded-inputs.sha256"
            runtime.write_bytes(b"runtime")
            manifest.write_text(
                "blorp-sha256 " + ("0" * 64) + "\n",
                encoding="utf-8",
            )

            stale = self.fast_loop.stale_embedded_inputs(
                root,
                manifest,
                ("runtime.c",),
            )

            self.assertEqual(stale, ["runtime.c"])

    def test_fast_loop_rejects_malformed_input_manifests(self) -> None:
        digest = hashlib.sha256(b"content").hexdigest()
        invalid_manifests = (
            b"",
            f"{digest}  source.brp".encode(),
            f"{digest[:-1]}  source.brp\n".encode(),
            f"{'g' * 64}  source.brp\n".encode(),
            f"{digest} source.brp\n".encode(),
            f"{digest}  \n".encode(),
            f"{digest}  source.brp\n{digest}  source.brp\n".encode(),
            f"{digest}  z.brp\n{digest}  a.brp\n".encode(),
            b"\xff\n",
        )

        for data in invalid_manifests:
            with self.subTest(data=data):
                self.assertIsNone(
                    self.fast_loop.input_manifest_fingerprints(data),
                )

    def test_installed_compiler_must_match_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            manifest = root / "embedded-inputs.sha256"
            build_manifest = root / "build-inputs.sha256"
            compiler.write_bytes(b"installed compiler")
            build_manifest.write_text("", encoding="utf-8")
            manifest.write_text(
                "blorp-sha256 " + hashlib.sha256(b"other compiler").hexdigest() + "\n",
                encoding="utf-8",
            )

            self.assertFalse(
                self.fast_loop.installed_compiler_matches(
                    compiler,
                    build_manifest,
                    manifest,
                ),
            )

    def test_installed_compiler_matches_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            manifest = root / "embedded-inputs.sha256"
            build_manifest = root / "build-inputs.sha256"
            compiler_bytes = b"installed compiler"
            compiler.write_bytes(compiler_bytes)
            input_record = f"{hashlib.sha256(b'runtime').hexdigest()}  runtime.c\n"
            build_manifest.write_text(input_record, encoding="utf-8")
            manifest.write_text(
                (
                    "blorp-sha256 "
                    + hashlib.sha256(compiler_bytes).hexdigest()
                    + "\n"
                    + input_record
                ),
                encoding="utf-8",
            )

            self.assertTrue(
                self.fast_loop.installed_compiler_matches(
                    compiler,
                    build_manifest,
                    manifest,
                ),
            )

    def test_installed_compiler_rejects_incomplete_input_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            build_manifest = root / "build-inputs.sha256"
            installed_manifest = root / "embedded-inputs.sha256"
            compiler_bytes = b"installed compiler"
            compiler.write_bytes(compiler_bytes)
            build_manifest.write_text(
                f"{hashlib.sha256(b'runtime').hexdigest()}  runtime.c\n",
                encoding="utf-8",
            )
            installed_manifest.write_text(
                "blorp-sha256 " + hashlib.sha256(compiler_bytes).hexdigest() + "\n",
                encoding="utf-8",
            )

            self.assertFalse(
                self.fast_loop.installed_compiler_matches(
                    compiler,
                    build_manifest,
                    installed_manifest,
                ),
            )

    def test_run_case_rejects_stale_input_before_launch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            runtime = root / "runtime.c"
            manifest = root / self.fast_loop.EMBEDDED_INPUT_MANIFEST
            build_manifest = root / self.fast_loop.BUILD_INPUT_MANIFEST
            compiler.write_bytes(b"compiler")
            compiler.chmod(0o755)
            runtime.write_bytes(b"changed")
            manifest.parent.mkdir(parents=True)
            input_record = f"{hashlib.sha256(b'built').hexdigest()}  runtime.c\n"
            build_manifest.write_text(input_record, encoding="utf-8")
            manifest.write_text(
                (
                    "blorp-sha256 "
                    + hashlib.sha256(b"compiler").hexdigest()
                    + "\n"
                    + input_record
                ),
                encoding="utf-8",
            )
            case = self.fast_loop.FastCase(
                command=("ignored",),
                source_paths=("runtime.c",),
                median_budget_seconds=1.0,
                supervisor_timeout_seconds=1.0,
            )

            with mock.patch.object(
                self.fast_loop,
                "project_root",
                return_value=root,
            ), mock.patch.object(
                self.fast_loop.subprocess,
                "Popen",
            ) as popen, mock.patch.object(sys, "stderr", new=io.StringIO()):
                status = self.fast_loop.run_case("stale", case, 1)

            self.assertEqual(status, 1)
            popen.assert_not_called()

    def test_run_case_launches_when_embedded_inputs_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / "blorp"
            runtime = root / "runtime.c"
            manifest = root / self.fast_loop.EMBEDDED_INPUT_MANIFEST
            build_manifest = root / self.fast_loop.BUILD_INPUT_MANIFEST
            compiler.write_bytes(b"compiler")
            compiler.chmod(0o755)
            runtime_bytes = b"runtime"
            runtime.write_bytes(runtime_bytes)
            manifest.parent.mkdir(parents=True)
            input_record = f"{hashlib.sha256(runtime_bytes).hexdigest()}  runtime.c\n"
            build_manifest.write_text(input_record, encoding="utf-8")
            manifest.write_text(
                (
                    "blorp-sha256 "
                    + hashlib.sha256(b"compiler").hexdigest()
                    + "\n"
                    + input_record
                ),
                encoding="utf-8",
            )
            case = self.fast_loop.FastCase(
                command=("ignored",),
                source_paths=("runtime.c",),
                median_budget_seconds=1.0,
                supervisor_timeout_seconds=1.0,
            )
            process = mock.Mock(returncode=0)
            supervision = self.fast_loop.SupervisedProcessResult(
                timed_out=False,
                descendants_at_exit=frozenset(),
                cleanup_survivors=frozenset(),
                stdout=b"",
                stderr=b"",
            )

            with mock.patch.object(
                self.fast_loop,
                "project_root",
                return_value=root,
            ), mock.patch.object(
                self.fast_loop,
                "process_rows",
                return_value={},
            ), mock.patch.object(
                self.fast_loop.subprocess,
                "Popen",
                return_value=process,
            ) as popen, mock.patch.object(
                self.fast_loop,
                "supervise_process",
                return_value=supervision,
            ), mock.patch.object(sys, "stdout", new=io.StringIO()):
                status = self.fast_loop.run_case("fresh", case, 1)

            self.assertEqual(status, 0)
            popen.assert_called_once()

    def test_run_case_delivers_stdin_and_requires_output_fragments(self) -> None:
        case = self.fast_loop.FastCase(
            command=("ignored",),
            source_paths=("runtime.c",),
            median_budget_seconds=1.0,
            supervisor_timeout_seconds=1.0,
            stdin_bytes=b"request",
            expected_stdout=(b"stdout-marker",),
            expected_stderr=(b"stderr-marker",),
        )
        supervision = self.fast_loop.SupervisedProcessResult(
            timed_out=False,
            descendants_at_exit=frozenset(),
            cleanup_survivors=frozenset(),
            stdout=b"prefix stdout-marker suffix",
            stderr=b"prefix stderr-marker suffix",
        )
        stdin = mock.Mock()
        stdin.write.return_value = len(case.stdin_bytes)

        status, _ = self.run_verified_mock_case(case, supervision, stdin)

        self.assertEqual(status, 0)
        stdin.write.assert_not_called()

    def test_run_case_rejects_missing_output_fragment(self) -> None:
        case = self.fast_loop.FastCase(
            command=("ignored",),
            source_paths=("runtime.c",),
            median_budget_seconds=1.0,
            supervisor_timeout_seconds=1.0,
            expected_stdout=(b"required-marker",),
        )
        supervision = self.fast_loop.SupervisedProcessResult(
            timed_out=False,
            descendants_at_exit=frozenset(),
            cleanup_survivors=frozenset(),
            stdout=b"different output",
            stderr=b"",
        )

        status, _ = self.run_verified_mock_case(case, supervision, None)

        self.assertEqual(status, 1)

    def test_run_case_rejects_early_broken_stdin_pipe(self) -> None:
        case = self.fast_loop.FastCase(
            command=("ignored",),
            source_paths=("runtime.c",),
            median_budget_seconds=1.0,
            supervisor_timeout_seconds=1.0,
            stdin_bytes=b"request",
        )
        supervision = self.fast_loop.SupervisedProcessResult(
            timed_out=False,
            descendants_at_exit=frozenset(),
            cleanup_survivors=frozenset(),
            stdout=b"",
            stderr=b"",
            stdin_delivery_error="closed",
        )
        stdin = mock.Mock()

        status, _ = self.run_verified_mock_case(case, supervision, stdin)

        self.assertEqual(status, 1)

    def test_diagnostic_tail_is_bounded(self) -> None:
        tail = bytearray(b"prefix")
        self.fast_loop.append_diagnostic_tail(
            tail,
            b"a" * (self.fast_loop.DIAGNOSTIC_TAIL_BYTES + 17),
        )
        self.assertEqual(
            tail,
            b"a" * self.fast_loop.DIAGNOSTIC_TAIL_BYTES,
        )

    def test_timeout_safely_handles_descendant_in_a_separate_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import os, pathlib, subprocess, sys, time; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'], start_new_session=True); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                    "time.sleep(30)"
                ),
                str(child_pid_file),
            )
            started_at = time.monotonic()
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            process_rows_once = self.fast_loop.process_rows_once
            sample_attempts = 0

            def transient_sampler_failure():
                nonlocal sample_attempts
                sample_attempts += 1
                if sample_attempts == 2:
                    raise self.fast_loop.ProcessSamplingError("transient sampler failure")
                return process_rows_once()

            with mock.patch.object(
                self.fast_loop,
                "process_rows_once",
                side_effect=transient_sampler_failure,
            ):
                result = self.fast_loop.supervise_process(process, 0.25)
            elapsed = time.monotonic() - started_at

            self.assertTrue(result.timed_out)
            self.assertGreater(sample_attempts, 2)
            self.assertLess(elapsed, 4.0)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            try:
                if self.fast_loop.individual_process_signaling_supported():
                    self.assertFalse(result.cleanup_survivors)
                    deadline = time.monotonic() + 1.0
                    while (
                        self.fast_loop.process_id_is_alive(child_pid)
                        and time.monotonic() < deadline
                    ):
                        time.sleep(0.02)
                    self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))
                else:
                    self.assertTrue(
                        any(
                            identity.process_id == child_pid
                            for identity in result.cleanup_survivors
                        ),
                    )
            finally:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_sampler_loss_recovers_with_retained_descendant_identities(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "sampler-loss-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys, time; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                    "time.sleep(30)"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            process_rows_once = self.fast_loop.process_rows_once
            sample_attempts = 0

            def fail_one_complete_sample():
                nonlocal sample_attempts
                sample_attempts += 1
                if 2 <= sample_attempts <= 4:
                    raise self.fast_loop.ProcessSamplingError("forced sampler loss")
                return process_rows_once()

            with mock.patch.object(
                self.fast_loop,
                "DESCENDANT_POLL_SECONDS",
                0.0,
            ), mock.patch.object(
                self.fast_loop,
                "process_rows_once",
                side_effect=fail_one_complete_sample,
            ):
                with self.assertRaises(self.fast_loop.ProcessSamplingError):
                    self.fast_loop.supervise_process(process, 5.0)

            self.assertGreaterEqual(sample_attempts, 5)
            deadline = time.monotonic() + 1.0
            while self.fast_loop.process_id_is_alive(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))
            self.assertIsNotNone(process.returncode)

    def test_persistent_sampler_loss_still_kills_retained_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "persistent-loss-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys, time; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                    "time.sleep(30)"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(command, start_new_session=True)
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            birth_identity = self.fast_loop.process_birth_identity(child_pid)
            self.assertIsNotNone(birth_identity)
            identity = self.fast_loop.ProcessIdentity(child_pid, birth_identity)

            with mock.patch.object(
                self.fast_loop,
                "descendant_process_identities",
                side_effect=self.fast_loop.ProcessSamplingError("persistent sampler loss"),
            ):
                with self.assertRaises(self.fast_loop.ProcessSamplingError):
                    self.fast_loop.terminate_process_tree(process, {identity})

            deadline = time.monotonic() + 1.0
            while self.fast_loop.process_id_is_alive(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))
            self.assertIsNotNone(process.returncode)

    def test_untracked_continuous_writer_cannot_starve_final_drain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "writer-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "\"import os; chunk=b'z' * 65536; exec('while True:\\\\n os.write(1, chunk)')\"], "
                    "start_new_session=True); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            self.assertTrue(
                self.wait_for_detached_child_after_leader_exit(process, child_pid),
            )
            try:
                started_at = time.monotonic()
                result = self.fast_loop.supervise_process(process, 0.25)
                self.assertFalse(result.timed_out)
                self.assertLess(time.monotonic() - started_at, 1.0)
                self.assertEqual(len(result.stdout), self.fast_loop.DIAGNOSTIC_TAIL_BYTES)
            finally:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_fully_detached_child_is_outside_portable_tracking(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "detached-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import time; time.sleep(30)'], start_new_session=True); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(child_pid_file.exists())
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            self.assertTrue(
                self.wait_for_detached_child_after_leader_exit(process, child_pid),
            )
            try:
                result = self.fast_loop.supervise_process(process, 0.25)
                self.assertFalse(result.timed_out)
                self.assertFalse(result.descendants_at_exit)
                self.assertTrue(self.fast_loop.process_id_is_alive(child_pid))
            finally:
                try:
                    os.kill(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 1.0
                while (
                    self.fast_loop.process_id_is_alive(child_pid)
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.02)
                self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))

    def test_supervisor_bounds_both_output_tails_and_escalates(self) -> None:
        output_bytes = self.fast_loop.DIAGNOSTIC_TAIL_BYTES + 4096
        command = (
            sys.executable,
            "-c",
            (
                "import os, signal, time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                f"os.write(1, b'a' * {output_bytes}); "
                f"os.write(2, b'b' * {output_bytes}); "
                "time.sleep(30)"
            ),
        )
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

        started_at = time.monotonic()
        result = self.fast_loop.supervise_process(process, 0.25)

        self.assertTrue(result.timed_out)
        self.assertEqual(result.stdout, b"a" * self.fast_loop.DIAGNOSTIC_TAIL_BYTES)
        self.assertEqual(result.stderr, b"b" * self.fast_loop.DIAGNOSTIC_TAIL_BYTES)
        self.assertLess(time.monotonic() - started_at, 3.0)
        self.assertIsNotNone(process.returncode)

    def test_continuous_output_cannot_starve_timeout(self) -> None:
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import os, signal; "
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                    "chunk=b'x' * 65536; "
                    "exec('while True:\\n os.write(1, chunk)')"
                ),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

        started_at = time.monotonic()
        result = self.fast_loop.supervise_process(process, 0.25)

        self.assertTrue(result.timed_out)
        self.assertEqual(len(result.stdout), self.fast_loop.DIAGNOSTIC_TAIL_BYTES)
        self.assertLess(time.monotonic() - started_at, 3.0)
        self.assertIsNotNone(process.returncode)

    def test_stdin_backpressure_cannot_starve_timeout(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )

        started_at = time.monotonic()
        result = self.fast_loop.supervise_process(
            process,
            0.25,
            b"x" * (8 * 1024 * 1024),
        )

        self.assertTrue(result.timed_out)
        self.assertLess(time.monotonic() - started_at, 3.0)
        self.assertIsNotNone(process.returncode)

    def test_supervisor_delivers_complete_stdin(self) -> None:
        process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; data=sys.stdin.buffer.read(); print(len(data))",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        input_bytes = b"input" * 128 * 1024

        result = self.fast_loop.supervise_process(process, 2.0, input_bytes)

        self.assertFalse(result.timed_out)
        self.assertIsNone(result.stdin_delivery_error)
        self.assertEqual(result.stdout.strip(), str(len(input_bytes)).encode("ascii"))
        self.assertEqual(process.returncode, 0)

    def test_interruption_cleans_observed_same_group_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "interrupted-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import os, pathlib, subprocess, sys; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                    "chunk=b'x' * 4096; exec('while True:\\n os.write(1, chunk)')"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))

            with mock.patch.object(
                self.fast_loop,
                "drain_ready_pipe",
                side_effect=self.fast_loop.FastLoopInterrupted(signal.SIGINT),
            ):
                with self.assertRaises(self.fast_loop.FastLoopInterrupted):
                    self.fast_loop.supervise_process(process, 5.0)

            deadline = time.monotonic() + 1.0
            while self.fast_loop.process_id_is_alive(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))
            self.assertIsNotNone(process.returncode)

    def test_signal_termination_kills_the_supervised_process_tree(self) -> None:
        process = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            start_new_session=True,
        )
        try:
            descendants = self.fast_loop.terminate_process_tree(process, set())
            self.assertEqual(descendants, set())
            self.assertIsNotNone(process.returncode)
            self.assertFalse(self.fast_loop.process_id_is_alive(process.pid))
        finally:
            if process.poll() is None:
                os.kill(process.pid, signal.SIGKILL)
                process.wait()

    def test_group_fallback_does_not_signal_after_leader_is_reaped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "group-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys, time; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)']); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(command, start_new_session=True)
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))
            process.wait(timeout=2.0)

            with mock.patch.object(self.fast_loop.os, "killpg") as kill_group:
                self.fast_loop.terminate_root_process_group(process)

            kill_group.assert_not_called()
            self.assertTrue(self.fast_loop.process_id_is_alive(child_pid))
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_group_fallback_uses_owned_unreaped_leader_without_resampling(self) -> None:
        process = mock.Mock(pid=41, returncode=None)

        with mock.patch.object(
            self.fast_loop,
            "process_birth_identity",
            side_effect=AssertionError("owned leader must not be resampled"),
        ), mock.patch.object(self.fast_loop.os, "killpg") as kill_group:
            self.fast_loop.terminate_root_process_group(process)

        self.assertEqual(
            kill_group.call_args_list,
            [mock.call(41, signal.SIGTERM), mock.call(41, signal.SIGKILL)],
        )
        process.wait.assert_called_once_with(
            timeout=self.fast_loop.TERMINATION_GRACE_SECONDS,
        )

    def test_supervisor_tracks_same_group_child_after_leader_exits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "same-group-child.pid"
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys; "
                    "child=subprocess.Popen([sys.executable, '-c', "
                    "'import time; time.sleep(30)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                ),
                str(child_pid_file),
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not child_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(child_pid_file.exists())
            child_pid = int(child_pid_file.read_text(encoding="utf-8"))

            result = self.fast_loop.supervise_process(process, 0.25)

            self.assertFalse(result.timed_out)
            self.assertTrue(
                any(identity.process_id == child_pid for identity in result.descendants_at_exit)
            )
            deadline = time.monotonic() + 1.0
            while self.fast_loop.process_id_is_alive(child_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(self.fast_loop.process_id_is_alive(child_pid))

    def test_cleanup_resamples_same_group_child_forked_during_termination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child_pid_file = Path(directory) / "terminating-child.pid"
            forked_pid_file = Path(directory) / "forked-child.pid"
            ready_file = Path(directory) / "terminating-child.ready"
            child_source = (
                "import os, pathlib, signal, sys, time; "
                "target=sys.argv[1]; ready=sys.argv[2]; "
                "exec(\"def terminate(*_):\\n"
                " child=os.fork()\\n"
                " if child == 0:\\n"
                "  signal.signal(signal.SIGTERM, signal.SIG_IGN)\\n"
                "  pathlib.Path(target).write_text(str(os.getpid()))\\n"
                "  time.sleep(30)\\n"
                "  os._exit(0)\\n"
                " os._exit(0)\"); "
                "signal.signal(signal.SIGTERM, terminate); "
                "pathlib.Path(ready).write_text('ready'); time.sleep(30)"
            )
            command = (
                sys.executable,
                "-c",
                (
                    "import pathlib, subprocess, sys; "
                    "child=subprocess.Popen([sys.executable, '-c', sys.argv[4], sys.argv[2], sys.argv[3]], "
                    "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                ),
                str(child_pid_file),
                str(forked_pid_file),
                str(ready_file),
                child_source,
            )
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            deadline = time.monotonic() + 1.0
            while not ready_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready_file.exists())

            result = self.fast_loop.supervise_process(process, 0.25)

            self.assertFalse(result.cleanup_survivors)
            deadline = time.monotonic() + 1.0
            while not forked_pid_file.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(forked_pid_file.exists())
            forked_pid = int(forked_pid_file.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 1.0
            while self.fast_loop.process_id_is_alive(forked_pid) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertFalse(self.fast_loop.process_id_is_alive(forked_pid))

    def test_signaling_rejects_reused_process_identity(self) -> None:
        stale_identity = self.fast_loop.ProcessIdentity(
            process_id=os.getpid(),
            birth_identity="not-the-current-process-birth-time",
        )
        with mock.patch.object(self.fast_loop.os, "kill") as kill:
            self.fast_loop.signal_processes({stale_identity}, signal.SIGTERM)
        kill.assert_not_called()

    def test_linux_signaling_uses_identity_validated_pidfd(self) -> None:
        identity = self.fast_loop.ProcessIdentity(41, "linux:birth-41")

        with mock.patch.object(
            self.fast_loop.sys,
            "platform",
            "linux",
        ), mock.patch.object(
            self.fast_loop.os,
            "pidfd_open",
            return_value=17,
            create=True,
        ) as pidfd_open, mock.patch.object(
            self.fast_loop,
            "process_birth_identity",
            return_value=identity.birth_identity,
        ), mock.patch.object(
            self.fast_loop.signal,
            "pidfd_send_signal",
            create=True,
        ) as pidfd_send_signal, mock.patch.object(
            self.fast_loop.os,
            "close",
        ) as close, mock.patch.object(self.fast_loop.os, "kill") as kill:
            self.fast_loop.signal_processes({identity}, signal.SIGTERM)

        pidfd_open.assert_called_once_with(identity.process_id, 0)
        pidfd_send_signal.assert_called_once_with(17, signal.SIGTERM)
        close.assert_called_once_with(17)
        kill.assert_not_called()

    def test_linux_pidfd_resource_failure_fails_closed(self) -> None:
        identity = self.fast_loop.ProcessIdentity(41, "linux:birth-41")

        with mock.patch.object(
            self.fast_loop.sys,
            "platform",
            "linux",
        ), mock.patch.object(
            self.fast_loop.os,
            "pidfd_open",
            side_effect=OSError(24, "too many open files"),
            create=True,
        ), mock.patch.object(
            self.fast_loop.signal,
            "pidfd_send_signal",
            create=True,
        ), mock.patch.object(self.fast_loop.os, "kill") as kill:
            with self.assertRaises(self.fast_loop.ProcessSamplingError):
                self.fast_loop.signal_processes({identity}, signal.SIGKILL)

        kill.assert_not_called()

    def test_process_birth_identity_uses_kernel_start_time(self) -> None:
        identity = self.fast_loop.process_birth_identity(os.getpid())

        self.assertIsNotNone(identity)
        self.assertTrue(
            identity.startswith("linux:") or identity.startswith("darwin:"),
            identity,
        )

    def test_descendant_sampling_fails_closed_without_birth_identity(self) -> None:
        rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=10,
                state="S",
                birth_identity="",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            side_effect=(rows, rows),
        ):
            with self.assertRaisesRegex(
                self.fast_loop.ProcessSamplingError,
                "birth identity",
            ):
                self.fast_loop.descendant_process_identities(10)

    def test_descendant_sampling_ignores_confirmed_exit_during_identity_lookup(self) -> None:
        rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=10,
                state="S",
                birth_identity="birth-41",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            side_effect=(rows, {}),
        ):
            identities = self.fast_loop.descendant_process_identities(10)

        self.assertEqual(identities, set())

    def test_descendant_sampling_ignores_visible_zombie_without_birth_identity(self) -> None:
        rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=10,
                state="Z",
                birth_identity="",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            return_value=rows,
        ):
            identities = self.fast_loop.descendant_process_identities(10)

        self.assertEqual(identities, set())

    def test_descendant_sampling_retains_identity_across_reparenting(self) -> None:
        observed_rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=41,
                state="S",
                birth_identity="birth-41",
            ),
        }
        reparented_rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=1,
                process_group_id=41,
                state="S",
                birth_identity="birth-41",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            side_effect=(observed_rows, reparented_rows, reparented_rows),
        ):
            identities = self.fast_loop.descendant_process_identities(10)

        self.assertEqual(
            identities,
            {self.fast_loop.ProcessIdentity(41, "birth-41")},
        )

    def test_descendant_sampling_includes_same_group_replacement_between_snapshots(self) -> None:
        first_rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=10,
                state="S",
                birth_identity="birth-41",
            ),
        }
        replacement_rows = {
            42: self.fast_loop.ProcessRow(
                parent_process_id=1,
                process_group_id=10,
                state="S",
                birth_identity="birth-42",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            side_effect=(first_rows, replacement_rows, replacement_rows),
        ):
            identities = self.fast_loop.descendant_process_identities(10)

        self.assertEqual(
            identities,
            {self.fast_loop.ProcessIdentity(42, "birth-42")},
        )

    def test_descendant_sampling_rejects_same_pid_with_changed_birth_identity(self) -> None:
        first_rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=10,
                process_group_id=10,
                state="S",
                birth_identity="birth-original",
            ),
        }
        replacement_rows = {
            41: self.fast_loop.ProcessRow(
                parent_process_id=1,
                process_group_id=1,
                state="S",
                birth_identity="birth-replacement",
            ),
        }

        with mock.patch.object(
            self.fast_loop,
            "process_rows",
            side_effect=(first_rows, replacement_rows, replacement_rows),
        ):
            identities = self.fast_loop.descendant_process_identities(10)

        self.assertEqual(identities, set())

    def test_darwin_process_sampling_rejects_saturated_pid_buffers(self) -> None:
        proc_listpids = mock.Mock(side_effect=lambda _kind, _type, _buffer, size: 4 if size == 0 else size)

        with mock.patch.object(
            self.fast_loop,
            "darwin_libproc",
            return_value=(mock.Mock(), proc_listpids, mock.Mock()),
        ):
            with self.assertRaisesRegex(
                self.fast_loop.ProcessSamplingError,
                "capacity",
            ):
                self.fast_loop.darwin_process_rows()

    def test_process_sampling_errors_are_explicit(self) -> None:
        with mock.patch.object(
            self.fast_loop.sys,
            "platform",
            "unsupported",
        ):
            with self.assertRaises(self.fast_loop.ProcessSamplingError):
                self.fast_loop.process_rows()


if __name__ == "__main__":
    unittest.main()
