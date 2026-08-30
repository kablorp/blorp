#!/usr/bin/env python3
"""Gating process measurements for the production Blorp-owned LSP.

The test deliberately reports rather than enforces wall-clock thresholds.
Compiler startup, filesystem state, and shared CI hosts make fixed latency
thresholds noisy, but the protocol lifecycle and stale-result contract must
remain covered by the required LSP gate. Its cleanup path always closes the
process group through ``LspClient``.
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import sys
import time
import unittest
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[3]
BLORP = pathlib.Path(os.environ.get("BLORP_TEST_BINARY", ROOT / "bin" / "blorp")).resolve()
MEASUREMENT_TIMEOUT_SECONDS = 60.0
RUNNER_PATH = pathlib.Path(__file__).with_name("run_lsp_fixtures.py")
RUNNER_SPEC = importlib.util.spec_from_file_location("run_lsp_fixtures", RUNNER_PATH)
if RUNNER_SPEC is None or RUNNER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {RUNNER_PATH}")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
sys.modules[RUNNER_SPEC.name] = RUNNER
RUNNER_SPEC.loader.exec_module(RUNNER)


def workspace_source_metrics() -> tuple[int, int]:
    file_count = 0
    source_bytes = 0
    for directory in (ROOT / "blorp/src/compiler", ROOT / "std"):
        for path in directory.rglob("*.brp"):
            if path.is_file():
                file_count += 1
                source_bytes += path.stat().st_size
    return file_count, source_bytes


class NativeLspMeasurementTests(unittest.TestCase):
    def test_initialize_and_rapid_edit_measurements(self) -> None:
        client = None
        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "blorp/test/lsp/fixtures/completion/list_receiver_methods.brp"
            source = RUNNER.parse_marked_source(source_path).text
            uri = source_path.as_uri()
            old_source = source.replace("grown.length()", "old_missing_name")
            newest_source = source.replace("grown.length()", "newest_missing_name")

            client = RUNNER.LspClient(str(BLORP), ROOT)
            initialize_started = time.monotonic()
            client.initialize(ROOT.as_uri(), expected_version)
            initialize_seconds = time.monotonic() - initialize_started

            open_started = time.monotonic()
            client.open_document_without_wait(uri, source)
            client.change_document_without_wait(uri, 2, old_source)
            client.change_document_without_wait(uri, 3, newest_source)

            publications: list[dict[str, Any]] = []
            newest_seen = False
            deadline = time.monotonic() + MEASUREMENT_TIMEOUT_SECONDS
            while not newest_seen:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail("timed out waiting for newest diagnostic publication")
                message = client.read_matching_until(
                    lambda value: value.get("method")
                    == "textDocument/publishDiagnostics"
                    and value.get("params", {}).get("uri") == uri,
                    remaining,
                )
                diagnostics = message.get("params", {}).get("diagnostics", [])
                publications.append(message)
                newest_seen = any(
                    "newest_missing_name" in str(diagnostic.get("message", ""))
                    for diagnostic in diagnostics
                )

            diagnostic_seconds = time.monotonic() - open_started
            obsolete_publications = sum(
                1
                for message in publications
                if "old_missing_name" in str(message)
            )
            file_count, source_bytes = workspace_source_metrics()

            print(
                "LSP_BASELINE "
                f"initialize_ms={initialize_seconds * 1000:.1f} "
                f"diagnostics_ms={diagnostic_seconds * 1000:.1f} "
                f"publications={len(publications)} "
                f"obsolete_publications={obsolete_publications} "
                f"workspace_brp_files={file_count} "
                f"workspace_source_bytes={source_bytes}",
            )
            self.assertEqual(obsolete_publications, 0)
        finally:
            if client is not None:
                client.close()


if __name__ == "__main__":
    unittest.main()
