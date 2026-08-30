#!/usr/bin/env python3
"""Process contract for the production Blorp-owned LSP baseline."""

from __future__ import annotations

import importlib.util
import os
import pathlib
import select
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
BLORP = pathlib.Path(os.environ.get("BLORP_TEST_BINARY", ROOT / "bin" / "blorp")).resolve()
RUNNER_PATH = pathlib.Path(__file__).with_name("run_lsp_fixtures.py")
RUNNER_SPEC = importlib.util.spec_from_file_location("run_lsp_fixtures", RUNNER_PATH)
if RUNNER_SPEC is None or RUNNER_SPEC.loader is None:
    raise RuntimeError(f"cannot load {RUNNER_PATH}")
RUNNER = importlib.util.module_from_spec(RUNNER_SPEC)
sys.modules[RUNNER_SPEC.name] = RUNNER
RUNNER_SPEC.loader.exec_module(RUNNER)

class NativeLspBaselineTests(unittest.TestCase):
    def test_clean_eof_before_initialize_is_successful_shutdown(self) -> None:
        client = RUNNER.LspClient(str(BLORP), ROOT)
        try:
            self.assertIsNotNone(client.proc.stdin)
            client.proc.stdin.close()
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            client.close()

    def test_public_command_uses_native_lifecycle_server(self) -> None:
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
                timeout=RUNNER.INITIALIZE_TIMEOUT_SECONDS,
            )

            self.assertEqual(
                result.get("serverInfo"),
                {"name": "blorp", "version": expected_version},
            )
            self.assertEqual(
                result.get("capabilities"),
                {
                    "positionEncoding": "utf-16",
                    "textDocumentSync": {
                        "openClose": True,
                        "change": 1,
                        "save": {"includeText": False},
                    },
                    "definitionProvider": True,
                    "referencesProvider": True,
                    "documentSymbolProvider": True,
                    "documentHighlightProvider": True,
                    "hoverProvider": True,
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

    def test_open_document_runs_native_compiler_analysis(self) -> None:
        previous_stack_size = os.environ.get("BLORP_FIBER_STACK_SIZE")
        os.environ["BLORP_FIBER_STACK_SIZE"] = str(128 * 1024)
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/completion/list_receiver_methods.brp"
            source = RUNNER.parse_marked_source(source_path).text

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(
                ROOT.as_uri(),
                expected_version,
                capabilities={
                    "textDocument": {
                        "publishDiagnostics": {"versionSupport": True}
                    }
                },
            )

            client.open_document_without_wait(source_path.as_uri(), source)
            initial_publication = client.wait_for_diagnostics_message(
                source_path.as_uri()
            )
            self.assertEqual(initial_publication.get("params", {}).get("version"), 1)
            diagnostics = initial_publication.get("params", {}).get("diagnostics", [])
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
            if previous_stack_size is None:
                os.environ.pop("BLORP_FIBER_STACK_SIZE", None)
            else:
                os.environ["BLORP_FIBER_STACK_SIZE"] = previous_stack_size

    def test_document_effects_complete_before_the_next_client_event(self) -> None:
        client = None
        scratch = ROOT / "scratch"
        scratch.mkdir(parents=True, exist_ok=True)

        with tempfile.TemporaryDirectory(
            prefix="blorp-lsp-document-order.",
            dir=scratch,
        ) as tmp:
            workspace = pathlib.Path(tmp)
            source_path = workspace / "main.brp"
            source_path.write_text("VALUE: Int = 1\n", encoding="utf-8")
            uri = source_path.as_uri()

            try:
                expected_version = RUNNER.public_compiler_version(
                    str(BLORP), ROOT
                )
                client = RUNNER.LspClient(str(BLORP), workspace)
                client.initialize(workspace.as_uri(), expected_version)

                self.assertEqual(
                    client.open_document(uri, "VALUE: Int = 1\n"),
                    [],
                )

                overlay_source = "OVERLAY_VALUE: Int = 2\n"
                client.change_document_without_wait(
                    uri,
                    2,
                    overlay_source,
                )

                saved_source = "DISK_VALUE: Int = 2\n"
                source_path.write_text(saved_source, encoding="utf-8")
                client.notify(
                    "textDocument/didSave",
                    {"textDocument": {"uri": uri}},
                )
                self.assertEqual(client.wait_for_diagnostics(uri), [])

                overlay_symbols = client.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": uri}},
                )
                self.assertTrue(
                    isinstance(overlay_symbols, list)
                    and any(
                        symbol.get("name") == "OVERLAY_VALUE"
                        for symbol in overlay_symbols
                    )
                )

                client.notify(
                    "textDocument/didClose",
                    {"textDocument": {"uri": uri}},
                )
                # Closing clears diagnostics for the retired overlay identity
                # and removes the closed document from the analysis roots.
                self.assertEqual(client.wait_for_diagnostics(uri), [])

                closed_symbols = client.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": uri}},
                )
                self.assertIsNone(closed_symbols)

                self.assertEqual(client.open_document(uri, saved_source), [])
                disk_symbols = client.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": uri}},
                )
                self.assertTrue(
                    isinstance(disk_symbols, list)
                    and any(
                        symbol.get("name") == "DISK_VALUE"
                        for symbol in disk_symbols
                    )
                    and all(
                        symbol.get("name") != "OVERLAY_VALUE"
                        for symbol in disk_symbols
                    )
                )
            finally:
                if client is not None:
                    client.close()

    def test_definition_from_call_returns_declaration_location(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/navigation/local_function.brp"
            source = RUNNER.parse_marked_source(source_path)
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(source_path.parent.as_uri(), expected_version)
            definition_params = {
                "textDocument": {"uri": uri},
                "position": {
                    "line": source.markers["add_use"].line,
                    "character": source.markers["add_use"].character,
                },
            }

            self.assertIsNone(
                client.request("textDocument/definition", definition_params)
            )
            self.assertEqual(client.open_document(uri, source.text), [])

            client.notify("textDocument/definition", definition_params)

            with self.assertRaisesRegex(RUNNER.LspError, "Invalid params"):
                client.request(
                    "textDocument/definition",
                    {"textDocument": {"uri": uri}},
                )

            self.assertFalse(
                any(
                    message.get("method") is None
                    and message.get("id") is None
                    and ("result" in message or "error" in message)
                    for message in client.pending_messages
                )
            )

            locations = client.request(
                "textDocument/definition",
                definition_params,
            )

            self.assertEqual(len(locations), 1)
            self.assertEqual(locations[0].get("uri"), uri)
            definition_range = locations[0].get("range", {})
            declaration_line = source.markers["add_decl"].line
            declaration_end_line = declaration_line + 1
            self.assertEqual(
                definition_range,
                {
                    "start": {
                        "line": declaration_line,
                        "character": source.text.splitlines()[declaration_line].index(
                            "func"
                        ),
                    },
                    "end": {
                        "line": declaration_end_line,
                        "character": len(source.text.splitlines()[declaration_end_line]),
                    },
                },
            )

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_definitions_traverse_selective_imports_to_unopened_provider(self) -> None:
        client = None

        with tempfile.TemporaryDirectory(prefix="blorp-lsp-definition-import.") as temp:
            workspace = pathlib.Path(temp)
            provider_path = workspace / "provider.brp"
            importer_path = workspace / "main.brp"
            provider_lines = [
                "ANSWER: Int = 42",
                "",
                "pure func answer() -> Int:",
                "\tANSWER",
                "",
                "record Box {",
                "\tvalue: Int",
                "}",
                "",
                "union Choice:",
                "\tNoChoice",
                "\tSelected(Int)",
            ]
            importer_lines = [
                "import:",
                "\tprovider:",
                "\t\tANSWER,",
                "\t\tBox,",
                "\t\tChoice(Selected),",
                "\t\tanswer",
                "",
                "pure func read_answer() -> Int:",
                "\tanswer() + ANSWER",
                "",
                "pure func read_box(box: Box) -> Int:",
                "\tbox.value",
                "",
                "pure func make_choice() -> Choice:",
                "\tSelected(ANSWER)",
            ]
            provider_source = "\n".join(provider_lines) + "\n"
            importer_source = "\n".join(importer_lines) + "\n"
            provider_path.write_text(provider_source, encoding="utf-8")
            importer_path.write_text(importer_source, encoding="utf-8")
            provider_uri = provider_path.as_uri()
            importer_uri = importer_path.as_uri()

            cases = [
                (8, importer_lines[8].index("answer"), 2),
                (8, importer_lines[8].index("ANSWER"), 0),
                (10, importer_lines[10].index("Box"), 5),
                (11, importer_lines[11].index("value"), 6),
                (13, importer_lines[13].index("Choice"), 9),
                (14, importer_lines[14].index("Selected"), 11),
            ]

            try:
                expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
                client = RUNNER.LspClient(str(BLORP), workspace)
                client.initialize(
                    workspace.as_uri(),
                    expected_version,
                    capabilities={
                        "textDocument": {
                            "publishDiagnostics": {"versionSupport": True}
                        }
                    },
                )

                # The unopened provider must be part of the proved closed-source
                # workspace index before CLion opens only the importing file.
                self.assertEqual(client.wait_for_diagnostics(importer_uri), [])
                self.assertEqual(client.wait_for_diagnostics(provider_uri), [])
                client.open_document_without_wait(importer_uri, importer_source)
                opened_publication = client.read_matching_until(
                    lambda message: message.get("method")
                    == "textDocument/publishDiagnostics"
                    and message.get("params", {}).get("uri") == importer_uri
                    and message.get("params", {}).get("version") == 1,
                    RUNNER.DIAGNOSTIC_TIMEOUT_SECONDS,
                )
                self.assertEqual(
                    opened_publication.get("params", {}).get("diagnostics"),
                    [],
                )
                symbols = client.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": importer_uri}},
                )
                self.assertIsInstance(symbols, list, client.stderr_text())

                for source_line, source_character, target_line in cases:
                    with self.subTest(source_line=source_line, target_line=target_line):
                        locations = client.request(
                            "textDocument/definition",
                            {
                                "textDocument": {"uri": importer_uri},
                                "position": {
                                    "line": source_line,
                                    "character": source_character,
                                },
                            },
                        )

                        self.assertIsInstance(locations, list)
                        self.assertEqual(len(locations), 1)
                        self.assertEqual(locations[0].get("uri"), provider_uri)
                        self.assertEqual(
                            locations[0].get("range", {}).get("start", {}).get("line"),
                            target_line,
                        )
            finally:
                if client is not None:
                    client.close()

    def test_document_symbols_return_compiler_owned_declarations(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/navigation/local_function.brp"
            source = RUNNER.parse_marked_source(source_path)
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(source_path.parent.as_uri(), expected_version)

            self.assertIsNone(
                client.request(
                    "textDocument/documentSymbol",
                    {"textDocument": {"uri": uri}},
                )
            )
            self.assertEqual(client.open_document(uri, source.text), [])

            symbols = client.request(
                "textDocument/documentSymbol",
                {"textDocument": {"uri": uri}},
            )
            self.assertIsInstance(symbols, list)
            names = {symbol.get("name") for symbol in symbols}
            self.assertTrue({"answer", "add", "main"}.issubset(names))

            add_symbol = next(symbol for symbol in symbols if symbol.get("name") == "add")
            self.assertEqual(
                add_symbol.get("selectionRange", {}).get("start"),
                {
                    "line": source.markers["add_def_name"].line,
                    "character": source.markers["add_def_name"].character,
                },
            )

            with self.assertRaisesRegex(RUNNER.LspError, "Invalid params"):
                client.request("textDocument/documentSymbol", {})

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_hover_returns_compiler_owned_typed_signature(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/navigation/local_function.brp"
            source = RUNNER.parse_marked_source(source_path)
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(source_path.parent.as_uri(), expected_version)
            self.assertEqual(client.open_document(uri, source.text), [])

            hover = client.request(
                "textDocument/hover",
                {
                    "textDocument": {"uri": uri},
                    "position": {
                        "line": source.markers["add_use"].line,
                        "character": source.markers["add_use"].character,
                    },
                },
            )

            self.assertEqual(
                hover.get("contents"),
                {"kind": "plaintext", "value": "add: (Int, Int) -> Int"},
            )
            self.assertEqual(
                hover.get("range"),
                {
                    "start": {
                        "line": source.markers["add_def_name"].line,
                        "character": source.markers["add_def_name"].character,
                    },
                    "end": {
                        "line": source.markers["add_def_name"].line,
                        "character": source.markers["add_def_name"].character + 3,
                    },
                },
            )

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_document_highlights_use_exact_symbol_ranges(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/navigation/local_function.brp"
            source = RUNNER.parse_marked_source(source_path)
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(source_path.parent.as_uri(), expected_version)
            self.assertEqual(client.open_document(uri, source.text), [])

            highlights = client.request(
                "textDocument/documentHighlight",
                {
                    "textDocument": {"uri": uri},
                    "position": {
                        "line": source.markers["add_use"].line,
                        "character": source.markers["add_use"].character,
                    },
                },
            )

            self.assertEqual(
                highlights,
                [
                    {
                        "range": {
                            "start": {
                                "line": source.markers["add_def_name"].line,
                                "character": source.markers["add_def_name"].character,
                            },
                            "end": {
                                "line": source.markers["add_def_name"].line,
                                "character": source.markers["add_def_name"].character + 3,
                            },
                        }
                    },
                    {
                        "range": {
                            "start": {
                                "line": source.markers["add_use"].line,
                                "character": source.markers["add_use"].character,
                            },
                            "end": {
                                "line": source.markers["add_use"].line,
                                "character": source.markers["add_use"].character + 3,
                            },
                        }
                    },
                ],
            )

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

    def test_references_return_null_for_incomplete_snapshot(self) -> None:
        client = None

        try:
            expected_version = RUNNER.public_compiler_version(str(BLORP), ROOT)
            source_path = ROOT / "tests/lsp/fixtures/navigation/local_function.brp"
            source = RUNNER.parse_marked_source(source_path)
            uri = source_path.as_uri()

            client = RUNNER.LspClient(str(BLORP), ROOT)
            client.initialize(source_path.parent.as_uri(), expected_version)
            self.assertEqual(client.open_document(uri, source.text), [])

            result = client.request(
                "textDocument/references",
                {
                    "textDocument": {"uri": uri},
                    "position": {
                        "line": source.markers["add_use"].line,
                        "character": source.markers["add_use"].character,
                    },
                    "context": {"includeDeclaration": True},
                },
            )

            self.assertIsNone(result)

            without_declaration = client.request(
                "textDocument/references",
                {
                    "textDocument": {"uri": uri},
                    "position": {
                        "line": source.markers["add_use"].line,
                        "character": source.markers["add_use"].character,
                    },
                    "context": {"includeDeclaration": False},
                },
            )
            self.assertIsNone(without_declaration)

            with self.assertRaisesRegex(RUNNER.LspError, "Invalid params"):
                client.request(
                    "textDocument/references",
                    {
                        "textDocument": {"uri": uri},
                        "position": {
                            "line": source.markers["add_use"].line,
                            "character": source.markers["add_use"].character,
                        },
                },
            )

            self.assertIsNone(
                client.request(
                    "textDocument/references",
                    {
                        "textDocument": {"uri": uri},
                        "position": {"line": 99, "character": 0},
                        "context": {"includeDeclaration": True},
                    },
                )
            )

            with self.assertRaisesRegex(RUNNER.LspError, "Invalid params"):
                client.request(
                    "textDocument/references",
                    {
                        "textDocument": {"uri": uri},
                        "position": {
                            "line": source.markers["add_use"].line,
                            "character": source.markers["add_use"].character,
                        },
                        "context": {},
                    },
                )

            with self.assertRaisesRegex(RUNNER.LspError, "Invalid params"):
                client.request(
                    "textDocument/references",
                    {
                        "textDocument": {"uri": uri},
                        "position": {
                            "line": source.markers["add_use"].line,
                            "character": source.markers["add_use"].character,
                        },
                        "context": {"includeDeclaration": "yes"},
                    },
                )

            self.assertIsNone(client.request("shutdown", None))
            client.notify("exit", None)
            client.proc.wait(timeout=RUNNER.DEFAULT_TIMEOUT_SECONDS)
            self.assertEqual(client.proc.returncode, 0)
        finally:
            if client is not None:
                client.close()

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
                / "blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/pkg_crypto_import.brp"
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
                / "blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/pkg_crypto_import.brp"
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
