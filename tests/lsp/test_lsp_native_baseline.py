#!/usr/bin/env python3
"""Process contract for the production Blorp-owned LSP baseline."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import select
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BLORP = pathlib.Path(os.environ.get("BLORP_TEST_BINARY", ROOT / "blorp")).resolve()
RUNNER_PATH = pathlib.Path(__file__).with_name("run_lsp_fixtures.py")
RUNNER_SPEC = importlib.util.spec_from_file_location("run_lsp_fixtures", RUNNER_PATH)
if RUNNER_SPEC is None or RUNNER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {RUNNER_PATH}")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
sys.modules[RUNNER_SPEC.name] = RUNNER
RUNNER_SPEC.loader.exec_module(RUNNER)


class NativeLspBaselineTests(unittest.TestCase):
    def test_public_command_uses_native_lifecycle_server(self) -> None:
        missing_host = ROOT / "missing-blorp-ocaml-host"
        previous_host = os.environ.get("BLORP_OCAML_HOST_BIN")
        os.environ["BLORP_OCAML_HOST_BIN"] = str(missing_host)
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            client = RUNNER.LspClient(str(BLORP), ROOT)
            result = client.request(
                "initialize",
                {
                    "processId": None,
                    "rootUri": ROOT.as_uri(),
                    "capabilities": {},
                },
            )

            self.assertEqual(
                result.get("serverInfo"),
                {"name": "blorp", "version": expected_version},
            )
            self.assertEqual(
                result.get("capabilities"),
                {
                    "positionEncoding": "utf-16",
                    "textDocumentSync": {"openClose": True, "change": 1},
                },
            )

            client.notify("initialized", {})
            with self.assertRaisesRegex(RUNNER.LspError, "Method not found"):
                client.request("workspace/nativeBaselineUnknown", None)

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()
            if previous_host is None:
                os.environ.pop("BLORP_OCAML_HOST_BIN", None)
            else:
                os.environ["BLORP_OCAML_HOST_BIN"] = previous_host

    def test_open_document_runs_native_compiler_analysis(self) -> None:
        missing_host = ROOT / "missing-blorp-ocaml-host"
        previous_host = os.environ.get("BLORP_OCAML_HOST_BIN")
        previous_stack_size = os.environ.get("BLORP_FIBER_STACK_SIZE")
        os.environ["BLORP_OCAML_HOST_BIN"] = str(missing_host)
        os.environ["BLORP_FIBER_STACK_SIZE"] = str(128 * 1024)
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            source = RUNNER.parse_marked_source(source_path).text

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)

            diagnostics = client.open_document(source_path.as_uri(), source)
            self.assertEqual(diagnostics, [])

            invalid_source = source.replace("grown.length()", "missing_name")
            diagnostics = client.change_document(
                source_path.as_uri(),
                2,
                invalid_source,
            )
            self.assertTrue(diagnostics)
            self.assertTrue(
                any(
                    diagnostic.get("source") == "blorp"
                    and diagnostic.get("code") in {"parse", "typecheck"}
                    for diagnostic in diagnostics
                )
            )

            diagnostics = client.change_document(source_path.as_uri(), 3, source)
            self.assertEqual(diagnostics, [])

            self.assertIsNone(client.request("shutdown", None))
            same_uri_publications = [
                message
                for message in client.pending_messages
                if message.get("method") == "textDocument/publishDiagnostics"
                and message.get("params", {}).get("uri") == source_path.as_uri()
            ]
            self.assertEqual(same_uri_publications, [])
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()
            if previous_host is None:
                os.environ.pop("BLORP_OCAML_HOST_BIN", None)
            else:
                os.environ["BLORP_OCAML_HOST_BIN"] = previous_host
            if previous_stack_size is None:
                os.environ.pop("BLORP_FIBER_STACK_SIZE", None)
            else:
                os.environ["BLORP_FIBER_STACK_SIZE"] = previous_stack_size

    def test_missing_import_publishes_exact_import_path_diagnostic(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = (
                ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            )
            source = (
                "import:\n"
                "\tmissing/module: value\n"
                "\n"
                "VALUE: Int = value\n"
            )
            expected_message = (
                "module 'missing/module' is not loaded for import registration"
            )

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            diagnostics = client.open_document(source_path.as_uri(), source)
            import_diagnostics = [
                diagnostic
                for diagnostic in diagnostics
                if diagnostic.get("message") == expected_message
            ]

            self.assertEqual(len(import_diagnostics), 1, diagnostics)
            self.assertEqual(import_diagnostics[0].get("source"), "blorp")
            self.assertEqual(import_diagnostics[0].get("code"), "typecheck")
            self.assertEqual(import_diagnostics[0].get("severity"), 1)
            self.assertEqual(
                import_diagnostics[0].get("range"),
                {
                    "start": {"line": 1, "character": 1},
                    "end": {"line": 1, "character": 15},
                },
            )

            self.assertIsNone(client.request("shutdown", None))
            same_uri_publications = [
                message
                for message in client.pending_messages
                if message.get("method") == "textDocument/publishDiagnostics"
                and message.get("params", {}).get("uri") == source_path.as_uri()
            ]
            self.assertEqual(same_uri_publications, [])
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_exit_is_not_blocked_by_a_client_that_stops_reading(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)

            request_id = client.next_id
            client.next_id += 1
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "workspace/" + ("unread" * 64 * 1024),
                    "params": None,
                }
            )

            self.assertIsNotNone(client.proc.stdout)
            readable, _, _ = select.select(
                [client.proc.stdout], [], [], RUNNER.DEFAULT_TIMEOUT_SECONDS
            )
            self.assertTrue(readable, "server did not begin the large response")

            client.notify("exit", None)
            client.proc.wait(timeout=2.0)
            self.assertEqual(client.proc.returncode, 1)
        finally:
            if client is not None:
                client.close()

    def test_standard_library_and_package_imports_resolve(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = (
                ROOT
                / "tests/test_compiler/typecheck/should_pass/pkg_crypto_import.brp"
            )

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            diagnostics = client.open_document(
                source_path.as_uri(), source_path.read_text(encoding="utf-8")
            )
            self.assertEqual(diagnostics, [])

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_implicit_tuple_implementation_typechecks(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            source = 'TUPLES_EQUAL: Bool = (1, "value") == (1, "value")\n'

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            self.assertEqual(
                client.open_document(source_path.as_uri(), source),
                [],
            )

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_close_clears_open_document_diagnostics(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            source = RUNNER.parse_marked_source(source_path).text
            invalid_source = source.replace("grown.length()", "missing_before_close")

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            self.assertEqual(client.open_document(source_path.as_uri(), source), [])
            diagnostics = client.change_document(
                source_path.as_uri(),
                2,
                invalid_source,
            )
            self.assertTrue(diagnostics)
            self.assertEqual(client.close_document(source_path.as_uri()), [])

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_rapid_edits_publish_only_the_newest_analysis(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = (
                ROOT
                / "tests/test_compiler/typecheck/should_pass/pkg_crypto_import.brp"
            )
            source = source_path.read_text(encoding="utf-8")
            old_source = source.replace("C.derive_key", "old_missing_name")
            newest_source = source.replace("C.derive_key", "newest_missing_name")
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            client.open_document_without_wait(uri, source)
            client.change_document_without_wait(uri, 2, old_source)
            client.change_document_without_wait(uri, 3, newest_source)

            observed: list[list[dict[str, object]]] = []
            for _ in range(3):
                diagnostics = client.wait_for_diagnostics(uri)
                observed.append(diagnostics)
                if any(
                    "newest_missing_name" in str(diagnostic.get("message", ""))
                    for diagnostic in diagnostics
                ):
                    break

            self.assertTrue(
                any(
                    "newest_missing_name" in str(diagnostic.get("message", ""))
                    for diagnostics in observed
                    for diagnostic in diagnostics
                )
            )
            self.assertFalse(
                any(
                    "old_missing_name" in str(diagnostic.get("message", ""))
                    for diagnostics in observed
                    for diagnostic in diagnostics
                )
            )

            self.assertEqual(client.change_document(uri, 4, source), [])
            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_shutdown_and_exit_do_not_wait_for_active_analysis(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            large_source = "\n".join(
                f"pure func active_exit_{index}(value: Int) -> Int: value + {index}"
                for index in range(2500)
            )

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)
            client.open_document_without_wait(source_path.as_uri(), large_source)

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=2.0)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_writer_failure_overrides_clean_lifecycle_exit(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(ROOT.as_uri(), expected_version)

            self.assertIsNotNone(client.proc.stdout)
            client.proc.stdout.close()
            request_id = client.next_id
            client.next_id += 1
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "shutdown",
                    "params": None,
                }
            )
            client.notify("exit", None)

            client.proc.wait(timeout=2.0)
            self.assertEqual(client.proc.returncode, 1)
            self.assertIn("LSP stdout write failed", client.stderr_text())
        finally:
            if client is not None:
                client.close()


if __name__ == "__main__":
    unittest.main()
