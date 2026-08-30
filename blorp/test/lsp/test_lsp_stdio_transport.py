#!/usr/bin/env python3
"""Process-level contract tests for the compiler-private LSP stdio transport."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "blorp/test/lsp/native_baseline/stdio_probe.brp"
READINESS_DELAY_SECONDS = 0.05
PROCESS_TIMEOUT_SECONDS = 10
SANITIZE = os.environ.get("BLORP_LSP_STDIO_SANITIZE") == "1"


class LspStdioTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory(prefix="blorp-lsp-stdio-")
        temp_path = Path(cls.temp_dir.name)
        generated_c = temp_path / "stdio_probe.c"
        cls.executable = temp_path / "stdio_probe"

        compile_result = subprocess.run(
            [
                str(ROOT / "bin" / "blorp"),
                "compile",
                "--no-format",
                "-o",
                str(generated_c),
                str(SOURCE),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(compile_result.stderr)

        compiler_flags = [
            "-O0",
            "-fwrapv",
            "-pipe",
            "-w",
        ]
        if SANITIZE:
            compiler_flags.extend(
                ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            )
        link_result = subprocess.run(
            [
                os.environ.get("CC", "cc"),
                *compiler_flags,
                str(generated_c),
                "-lm",
                "-lpthread",
                "-o",
                str(cls.executable),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if link_result.returncode != 0:
            raise AssertionError(link_result.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp_dir.cleanup()

    def test_delayed_fragmented_input_is_echoed_byte_for_byte(self) -> None:
        payload = (b"blorp\x00stdio\xc3\xa9\n" * 257) + bytes(range(256))
        process = subprocess.Popen(
            [str(self.executable), "echo"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert process.stdin is not None
        input_stream = process.stdin
        process.stdin = None
        writer_error: list[BaseException] = []

        def write_fragments() -> None:
            try:
                time.sleep(READINESS_DELAY_SECONDS)
                for offset in range(0, len(payload), 13):
                    input_stream.write(payload[offset : offset + 13])
                    input_stream.flush()
                input_stream.close()
            except BaseException as exc:
                writer_error.append(exc)

        writer = threading.Thread(target=write_fragments)
        writer.start()
        stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
        writer.join(timeout=PROCESS_TIMEOUT_SECONDS)

        self.assertFalse(writer.is_alive(), "fragment writer did not finish")
        self.assertEqual(writer_error, [])
        self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
        self.assertEqual(stdout, payload)

    def test_closed_stdin_is_reported_as_eof(self) -> None:
        completed = subprocess.run(
            [str(self.executable), "expect-eof"],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=PROCESS_TIMEOUT_SECONDS,
            check=False,
        )
        self.assertEqual(
            completed.returncode, 0, completed.stderr.decode(errors="replace")
        )

    def test_backpressured_write_completes_without_truncation(self) -> None:
        process = subprocess.Popen(
            [str(self.executable), "write-large"],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(READINESS_DELAY_SECONDS)
        stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)

        self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))
        self.assertEqual(len(stdout), 2 * 1024 * 1024)
        self.assertEqual(stdout, b"x" * len(stdout))

    def test_broken_stdout_pipe_is_a_typed_error_not_sigpipe(self) -> None:
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            process = subprocess.Popen(
                [str(self.executable), "expect-broken-pipe"],
                cwd=ROOT,
                stdin=subprocess.DEVNULL,
                stdout=write_fd,
                stderr=subprocess.PIPE,
            )
        finally:
            os.close(write_fd)

        _, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
        self.assertEqual(process.returncode, 0, stderr.decode(errors="replace"))

    def test_simultaneous_cancelled_waiters_release_both_slots(self) -> None:
        read_fd, write_fd = os.pipe()
        os.set_blocking(write_fd, False)
        try:
            while True:
                os.write(write_fd, b"x" * 4096)
        except BlockingIOError:
            pass

        process: subprocess.Popen[bytes] | None = None
        try:
            environment = dict(os.environ)
            environment["BLORP_LEAK_CHECK"] = "strict"
            process = subprocess.Popen(
                [str(self.executable), "cancel-waiters-twice"],
                cwd=ROOT,
                env=environment,
                stdin=subprocess.PIPE,
                stdout=write_fd,
                stderr=subprocess.PIPE,
            )
            os.close(write_fd)
            write_fd = -1

            returncode = process.wait(timeout=PROCESS_TIMEOUT_SECONDS)
            assert process.stdin is not None
            process.stdin.close()
            process.stdin = None
            _, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
            self.assertEqual(
                returncode,
                0,
                "simultaneous read/write waiters did not cancel cleanly:\n"
                + stderr.decode(errors="replace"),
            )
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            if write_fd >= 0:
                os.close(write_fd)
            os.close(read_fd)

    @unittest.skipIf(SANITIZE, "leak instrumentation is separate from ASan")
    def test_read_and_write_release_all_transport_values(self) -> None:
        environment = dict(os.environ)
        environment["BLORP_LEAK_CHECK"] = "1"
        completed = subprocess.run(
            [str(self.executable), "echo"],
            cwd=ROOT,
            env=environment,
            input=b"owned transport bytes\x00\xff",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=PROCESS_TIMEOUT_SECONDS,
            check=False,
        )

        stderr = completed.stderr.decode(errors="replace")
        self.assertEqual(completed.returncode, 0, stderr)
        self.assertEqual(completed.stdout, b"owned transport bytes\x00\xff")
        self.assertRegex(
            stderr,
            re.compile(
                r"blorp: leak check: ([0-9]+) allocs, "
                r"\1 releases, 0 leaked, 0 bytes"
            ),
        )


if __name__ == "__main__":
    unittest.main()
