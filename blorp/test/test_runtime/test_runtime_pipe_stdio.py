"""Internal pipes preserve closed standard descriptors on every creation path."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STANDARD_DESCRIPTOR_COUNT = 3

HARNESS = r'''
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int force_portable_pipe;
#if defined(__linux__)
static int probe_pipe2(int descriptors[2], int flags) {
    if (force_portable_pipe) {
        errno = ENOSYS;
        return -1;
    }
    return pipe2(descriptors, flags);
}
#define pipe2 probe_pipe2
#endif
#if defined(TEST_PORTABLE_DUPLICATION)
#undef F_DUPFD_CLOEXEC
#endif
#define MINICORO_IMPL
#include "minicoro.h"
#include "runtime.c"

enum Failure {
    INVALID_ARGUMENTS = 1, PIPE_CREATION_FAILED, STANDARD_DESCRIPTOR_REOPENED,
    INVALID_PIPE_DESCRIPTOR, MISSING_CLOEXEC, INCORRECT_BLOCKING_MODE,
    PAYLOAD_WRITE_FAILED, PAYLOAD_READ_FAILED
};

int main(int argc, char** argv) {
    if (argc != 4) return INVALID_ARGUMENTS;
    int closed_mask = atoi(argv[1]);
    force_portable_pipe = strcmp(argv[2], "portable") == 0;
    int nonblocking = strcmp(argv[3], "nonblocking") == 0;
    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; descriptor++) {
        if (closed_mask & (1 << descriptor)) close(descriptor);
    }

    int descriptors[2];
    int status = nonblocking
        ? blorp_runtime_pipe_cloexec_nonblock(descriptors)
        : blorp_runtime_pipe_cloexec(descriptors);
    if (status != 0) return PIPE_CREATION_FAILED;
    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; descriptor++) {
        if (!(closed_mask & (1 << descriptor))) continue;
        if (fcntl(descriptor, F_GETFD) != -1 || errno != EBADF)
            return STANDARD_DESCRIPTOR_REOPENED;
    }
    for (int endpoint = 0; endpoint < 2; endpoint++) {
        if (descriptors[endpoint] <= STDERR_FILENO) return INVALID_PIPE_DESCRIPTOR;
        int descriptor_flags = fcntl(descriptors[endpoint], F_GETFD);
        if (descriptor_flags < 0 || !(descriptor_flags & FD_CLOEXEC)) return MISSING_CLOEXEC;
        int status_flags = fcntl(descriptors[endpoint], F_GETFL);
        if (status_flags < 0 || !!(status_flags & O_NONBLOCK) != nonblocking)
            return INCORRECT_BLOCKING_MODE;
    }

    const unsigned char payload[] = {0, 'A', 255};
    unsigned char received[sizeof(payload)];
    if (write(descriptors[1], payload, sizeof(payload)) != sizeof(payload))
        return PAYLOAD_WRITE_FAILED;
    if (read(descriptors[0], received, sizeof(received)) != sizeof(received)
        || memcmp(received, payload, sizeof(payload)) != 0)
        return PAYLOAD_READ_FAILED;
    close(descriptors[0]);
    close(descriptors[1]);
    return 0;
}
'''


class RuntimePipeStdioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.directory = tempfile.TemporaryDirectory()
        cls.executables = {}
        for duplication in ("default", "portable"):
            executable = Path(cls.directory.name) / ("pipe-stdio-" + duplication)
            definitions = ["-DTEST_PORTABLE_DUPLICATION"] if duplication == "portable" else []
            compiled = subprocess.run(
                [os.environ.get("BLORP_CC", "clang"), "-std=gnu11", "-O0", "-fwrapv", "-w",
                 *definitions, f"-I{ROOT / 'blorp/src/lib/runtime/native'}", "-x", "c", "-",
                 "-lm", "-lpthread", "-o", str(executable)],
                cwd=ROOT, input=HARNESS, text=True, capture_output=True, check=False,
            )
            if compiled.returncode:
                cls.directory.cleanup()
                raise AssertionError(compiled.stderr)
            cls.executables[duplication] = executable

    @classmethod
    def tearDownClass(cls) -> None:
        cls.directory.cleanup()

    def check_closed_descriptors(self, creation: str, blocking: str) -> None:
        environment = dict(os.environ)
        environment.pop("BLORP_LEAK_CHECK", None)
        environment.pop("BLORP_MEMORY_STATS", None)
        # Close in main, after executable loading, so x64 translation cannot
        # occupy a closed descriptor before the runtime helper is exercised.
        for duplication, executable in self.executables.items():
            for closed_mask in range(1 << STANDARD_DESCRIPTOR_COUNT):
                with self.subTest(duplication=duplication, closed_mask=closed_mask):
                    result = subprocess.run(
                        [str(executable), str(closed_mask), creation, blocking],
                        cwd=ROOT, env=environment, stdin=subprocess.DEVNULL,
                        capture_output=True, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_pipe_preserves_closed_standard_descriptors(self) -> None:
        self.check_closed_descriptors("default", "blocking")

    def test_portable_pipe_preserves_closed_standard_descriptors(self) -> None:
        self.check_closed_descriptors("portable", "blocking")

    def test_default_nonblocking_pipe_preserves_closed_standard_descriptors(self) -> None:
        self.check_closed_descriptors("default", "nonblocking")

    def test_portable_nonblocking_pipe_preserves_closed_standard_descriptors(self) -> None:
        self.check_closed_descriptors("portable", "nonblocking")


if __name__ == "__main__":
    unittest.main()
