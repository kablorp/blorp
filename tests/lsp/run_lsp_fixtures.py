#!/usr/bin/env python3
"""Marker-based integration fixtures for the Blorp LSP server.

Fixture specs are JSON files next to .brp sources. Source files may contain
marker comment lines of the form:

    --    ^name

The caret column is the LSP character offset on the previous emitted source
line. Marker lines are removed before the document is sent to the server, so
fixtures can annotate incomplete or indentation-sensitive source without
affecting the program under test.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any


MARKER_PATTERN = re.compile(r"\^([A-Za-z_][A-Za-z0-9_-]*)")
DEFAULT_TIMEOUT_SECONDS = 10.0


class LspError(RuntimeError):
    pass


def emit_gate_result(status: str, passed: int, failed: int, tests: int) -> None:
    gate = os.environ.get("BLORP_GATE_RESULT")
    if gate:
        print(
            f"BLORP_GATE_RESULT gate={gate} status={status} "
            f"passed={passed} failed={failed} tests={tests}"
        )


@dataclass(frozen=True)
class Position:
    line: int
    character: int


@dataclass
class FixtureSource:
    text: str
    markers: dict[str, Position]


def parse_marked_source(path: pathlib.Path) -> FixtureSource:
    output_lines: list[str] = []
    markers: dict[str, Position] = {}

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        marker_matches = list(MARKER_PATTERN.finditer(raw_line))
        stripped = raw_line.lstrip()
        is_marker_line = stripped.startswith("--") and marker_matches

        if is_marker_line:
            if not output_lines:
                raise LspError(f"{path}: marker before any source line")
            target_line = len(output_lines) - 1
            for match in marker_matches:
                name = match.group(1)
                if name in markers:
                    raise LspError(f"{path}: duplicate marker '{name}'")
                markers[name] = Position(
                    line=target_line, character=match.start()
                )
            continue

        output_lines.append(raw_line)

    return FixtureSource(text="\n".join(output_lines) + "\n", markers=markers)


class LspClient:
    def __init__(self, blorp: str, cwd: pathlib.Path):
        self.stderr_file = tempfile.NamedTemporaryFile(
            mode="w+b", prefix="blorp-lsp-fixture-stderr.", delete=False
        )
        self.captured_stderr: str | None = None
        try:
            self.proc = subprocess.Popen(
                [blorp, "lsp"],
                cwd=str(cwd),
                bufsize=0,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr_file,
                start_new_session=os.name == "posix",
            )
        except Exception:
            stderr_path = pathlib.Path(self.stderr_file.name)
            self.stderr_file.close()
            try:
                stderr_path.unlink()
            except OSError:
                pass
            raise
        self.next_id = 1

    def process_group_exists(self) -> bool:
        if os.name != "posix":
            return self.proc.poll() is None
        try:
            os.killpg(self.proc.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def kill_process_group(self) -> None:
        if os.name == "posix":
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
                return
            except ProcessLookupError:
                return
        if self.proc.poll() is None:
            self.proc.kill()

    def close(self) -> None:
        close_error: Exception | None = None
        try:
            if self.proc.poll() is None:
                try:
                    self.request("shutdown", None)
                    self.notify("exit", None)
                    self.proc.wait(timeout=DEFAULT_TIMEOUT_SECONDS)
                except Exception:
                    self.kill_process_group()
                    self.proc.wait(timeout=DEFAULT_TIMEOUT_SECONDS)
            if self.process_group_exists():
                self.kill_process_group()
        except Exception as exc:
            close_error = exc
        finally:
            for stream in (self.proc.stdin, self.proc.stdout):
                if stream is not None:
                    stream.close()
            stderr_path = pathlib.Path(self.stderr_file.name)
            self.captured_stderr = self.stderr_text()
            self.stderr_file.close()
            try:
                stderr_path.unlink()
            except OSError:
                pass
        if close_error is not None:
            raise close_error

    def stderr_text(self) -> str:
        if self.captured_stderr is not None:
            return self.captured_stderr
        try:
            return pathlib.Path(self.stderr_file.name).read_text(
                encoding="utf-8", errors="replace"
            )
        except OSError:
            return ""

    def send(self, payload: dict[str, Any]) -> None:
        if self.proc.stdin is None:
            raise LspError("LSP stdin is closed")
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        self.proc.stdin.write(header + body)
        self.proc.stdin.flush()

    def notify(self, method: str, params: Any) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method: str, params: Any) -> Any:
        request_id = self.next_id
        self.next_id += 1
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            }
        )

        while True:
            message = self.read_message()
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise LspError(
                    f"{method} returned error: {json.dumps(message['error'])}"
                )
            return message.get("result")

    def read_available_line(self, timeout: float) -> bytes:
        if self.proc.stdout is None:
            raise LspError("LSP stdout is closed")
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise LspError("timed out waiting for LSP response")
        line = self.proc.stdout.readline()
        if line == b"":
            raise LspError("LSP server closed stdout")
        return line

    def read_exact(self, length: int, timeout: float) -> bytes:
        if self.proc.stdout is None:
            raise LspError("LSP stdout is closed")
        chunks: list[bytes] = []
        remaining = length
        deadline = time.monotonic() + timeout
        while remaining > 0:
            wait_time = max(0.0, deadline - time.monotonic())
            ready, _, _ = select.select([self.proc.stdout], [], [], wait_time)
            if not ready:
                raise LspError("timed out reading LSP response body")
            chunk = self.proc.stdout.read(remaining)
            if chunk == b"":
                raise LspError("LSP server closed stdout while reading body")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def read_message(self, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        content_length: int | None = None

        while True:
            wait_time = max(0.0, deadline - time.monotonic())
            line = self.read_available_line(wait_time)
            line = line.rstrip(b"\r\n")
            if line == b"":
                break
            header = line.decode("ascii", errors="replace")
            name, sep, value = header.partition(":")
            if sep and name.lower() == "content-length":
                content_length = int(value.strip())

        if content_length is None:
            raise LspError("LSP response missing Content-Length")

        wait_time = max(0.0, deadline - time.monotonic())
        body = self.read_exact(content_length, wait_time)
        return json.loads(body.decode("utf-8"))

    def initialize(self, root_uri: str, expected_version: str) -> None:
        result = self.request(
            "initialize",
            {"rootUri": root_uri, "capabilities": {}},
        )
        if not isinstance(result, dict) or "capabilities" not in result:
            raise LspError("initialize response did not include capabilities")
        server_info = result.get("serverInfo")
        if not isinstance(server_info, dict):
            raise LspError("initialize response did not include serverInfo")
        actual_version = server_info.get("version")
        if actual_version != expected_version:
            raise LspError(
                "initialize serverInfo.version did not match public compiler: "
                f"expected {expected_version!r}, got {actual_version!r}"
            )
        self.notify("initialized", {})

    def open_document(self, uri: str, text: str) -> list[dict[str, Any]]:
        self.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": uri,
                    "languageId": "blorp",
                    "version": 1,
                    "text": text,
                }
            },
        )

        while True:
            message = self.read_message()
            if message.get("method") != "textDocument/publishDiagnostics":
                continue
            params = message.get("params", {})
            if params.get("uri") == uri:
                return params.get("diagnostics", [])


def expect_contains(value: Any, expected: str, context: str) -> None:
    rendered = json.dumps(value, sort_keys=True)
    if expected not in rendered:
        raise AssertionError(f"{context}: expected substring {expected!r}")


def expect_diagnostics(diagnostics: list[dict[str, Any]], spec: Any, context: str) -> None:
    if spec is None:
        return
    if isinstance(spec, dict) and "count" in spec:
        expected_count = int(spec["count"])
        actual_count = len(diagnostics)
        if actual_count != expected_count:
            raise AssertionError(
                f"{context}: expected {expected_count} diagnostics, got {actual_count}"
            )
    if isinstance(spec, dict):
        for expected in spec.get("contains", []):
            expect_contains(diagnostics, expected, context)


def locations_from_result(result: Any) -> list[dict[str, Any]]:
    if result is None:
        return []
    if isinstance(result, list):
        return [normalize_location(location) for location in result]
    if isinstance(result, dict):
        return [normalize_location(result)]
    raise AssertionError(f"definition returned unexpected result: {result!r}")


def normalize_location(location: Any) -> dict[str, Any]:
    if not isinstance(location, dict):
        raise AssertionError(f"definition returned unexpected location: {location!r}")
    if "uri" in location and "range" in location:
        return location
    if "targetUri" in location:
        target_range = location.get("targetSelectionRange") or location.get(
            "targetRange"
        )
        if not isinstance(target_range, dict):
            raise AssertionError(
                f"definition LocationLink missing target range: {location!r}"
            )
        normalized = {"uri": location["targetUri"], "range": target_range}
        if "originSelectionRange" in location:
            normalized["originSelectionRange"] = location["originSelectionRange"]
        return normalized
    raise AssertionError(f"definition returned unsupported location shape: {location!r}")


def assert_definition(result: Any, expect: dict[str, Any], source: FixtureSource) -> None:
    locations = locations_from_result(result)
    if not locations:
        raise AssertionError("definition returned no locations")

    if "markers" in expect:
        starts = range_starts(locations)
        expected_starts = []
        for marker in expect.get("markers", []):
            if marker not in source.markers:
                raise AssertionError(f"definition: unknown expected marker '{marker}'")
            pos = source.markers[marker]
            expected_starts.append({"line": pos.line, "character": pos.character})

        missing = [start for start in expected_starts if start not in starts]
        if missing:
            raise AssertionError(
                f"definition: missing expected starts {missing}; got {starts}"
            )

        if expect.get("exact", False) and len(starts) != len(expected_starts):
            raise AssertionError(
                f"definition: expected exactly {expected_starts}; got {starts}"
            )

    target_name = expect.get("target")
    if target_name is not None:
        if target_name not in source.markers:
            raise AssertionError(f"unknown target marker '{target_name}'")
        target = source.markers[target_name]
        matching = [
            loc
            for loc in locations
            if loc.get("range", {}).get("start", {}) == {
                "line": target.line,
                "character": target.character,
            }
        ]
        if not matching:
            raise AssertionError(
                "definition did not include target marker "
                f"{target_name} at {target.line}:{target.character}; got {locations}"
            )

    target_line_name = expect.get("targetLine")
    if target_line_name is not None:
        if target_line_name not in source.markers:
            raise AssertionError(f"unknown targetLine marker '{target_line_name}'")
        target = source.markers[target_line_name]
        if not any(
            loc.get("range", {}).get("start", {}).get("line") == target.line
            for loc in locations
        ):
            raise AssertionError(
                "definition did not include target line marker "
                f"{target_line_name} at line {target.line}; got {locations}"
            )

    uri_suffix = expect.get("uriSuffix")
    if uri_suffix is not None:
        if not any(str(loc.get("uri", "")).endswith(uri_suffix) for loc in locations):
            raise AssertionError(f"definition URI did not end with {uri_suffix!r}")


def assert_hover(result: Any, expect: dict[str, Any]) -> None:
    if not isinstance(result, dict):
        raise AssertionError(f"hover returned unexpected result: {result!r}")
    contents = result.get("contents", {})
    value = contents.get("value") if isinstance(contents, dict) else contents
    for expected in expect.get("contains", []):
        if expected not in str(value):
            raise AssertionError(f"hover missing substring {expected!r}: {value!r}")


def assert_completion(result: Any, expect: dict[str, Any]) -> None:
    if not isinstance(result, dict):
        raise AssertionError(f"completion returned unexpected result: {result!r}")
    labels = {item.get("label") for item in result.get("items", [])}
    for label in expect.get("labels", []):
        if label not in labels:
            raise AssertionError(f"completion missing label {label!r}; got {labels}")
    for label in expect.get("absentLabels", []):
        if label in labels:
            raise AssertionError(
                f"completion included unexpected label {label!r}; got {labels}"
            )


def assert_signature_help(result: Any, expect: dict[str, Any]) -> None:
    if not isinstance(result, dict):
        raise AssertionError(f"signatureHelp returned unexpected result: {result!r}")
    if "activeParameter" in expect:
        actual = result.get("activeParameter")
        if actual != expect["activeParameter"]:
            raise AssertionError(
                f"expected activeParameter {expect['activeParameter']}, got {actual}"
            )
    labels = [
        signature.get("label", "")
        for signature in result.get("signatures", [])
        if isinstance(signature, dict)
    ]
    for expected in expect.get("labelContains", []):
        if not any(expected in label for label in labels):
            raise AssertionError(
                f"signature labels missing substring {expected!r}; got {labels}"
            )


def collect_symbol_names(symbols: list[dict[str, Any]]) -> set[str]:
    names: set[str] = set()
    for symbol in symbols:
        name = symbol.get("name")
        if isinstance(name, str):
            names.add(name)
        children = symbol.get("children")
        if isinstance(children, list):
            names.update(collect_symbol_names(children))
    return names


def assert_document_symbols(result: Any, expect: dict[str, Any]) -> None:
    if not isinstance(result, list):
        raise AssertionError(f"documentSymbol returned unexpected result: {result!r}")
    names = collect_symbol_names(result)
    for name in expect.get("names", []):
        if name not in names:
            raise AssertionError(f"document symbols missing {name!r}; got {names}")


def range_starts(result: Any) -> list[dict[str, int]]:
    if not isinstance(result, list):
        raise AssertionError(f"expected list result, got {result!r}")
    starts: list[dict[str, int]] = []
    for item in result:
        if not isinstance(item, dict):
            raise AssertionError(f"expected object item, got {item!r}")
        range_obj = item.get("range")
        if not isinstance(range_obj, dict):
            raise AssertionError(f"expected range object in {item!r}")
        start = range_obj.get("start")
        if not isinstance(start, dict):
            raise AssertionError(f"expected range start in {item!r}")
        starts.append(
            {
                "line": int(start.get("line")),
                "character": int(start.get("character")),
            }
        )
    return starts


def assert_marker_ranges(
    result: Any, expect: dict[str, Any], source: FixtureSource, method: str
) -> None:
    starts = range_starts(result)
    expected_markers = expect.get("markers", [])
    expected_starts = []
    for marker in expected_markers:
        if marker not in source.markers:
            raise AssertionError(f"{method}: unknown expected marker '{marker}'")
        pos = source.markers[marker]
        expected_starts.append({"line": pos.line, "character": pos.character})

    missing = [start for start in expected_starts if start not in starts]
    if missing:
        raise AssertionError(
            f"{method}: missing expected starts {missing}; got {starts}"
        )

    if expect.get("exact", False) and len(starts) != len(expected_starts):
        raise AssertionError(
            f"{method}: expected exactly {expected_starts}; got {starts}"
        )


def assert_inlay_hints(result: Any, expect: dict[str, Any], source: FixtureSource) -> None:
    if not isinstance(result, list):
        raise AssertionError(f"inlayHint returned unexpected result: {result!r}")
    hints = []
    for item in result:
        if not isinstance(item, dict):
            raise AssertionError(f"expected inlay hint object, got {item!r}")
        position = item.get("position")
        if not isinstance(position, dict):
            raise AssertionError(f"expected inlay hint position, got {item!r}")
        hints.append(
            {
                "line": int(position.get("line")),
                "character": int(position.get("character")),
                "label": str(item.get("label", "")),
            }
        )

    for expected in expect.get("hints", []):
        marker = expected["marker"]
        if marker not in source.markers:
            raise AssertionError(f"inlayHint: unknown expected marker '{marker}'")
        pos = source.markers[marker]
        label = expected.get("label")
        if not any(
            hint["line"] == pos.line
            and hint["character"] == pos.character
            and (label is None or hint["label"] == label)
            for hint in hints
        ):
            raise AssertionError(
                f"inlayHint: missing hint at {marker} "
                f"{pos.line}:{pos.character} label={label!r}; got {hints}"
            )

    for marker in expect.get("absentMarkers", []):
        if marker not in source.markers:
            raise AssertionError(f"inlayHint: unknown absent marker '{marker}'")
        pos = source.markers[marker]
        if any(
            hint["line"] == pos.line and hint["character"] == pos.character
            for hint in hints
        ):
            raise AssertionError(
                f"inlayHint: unexpected hint at absent marker {marker}; got {hints}"
            )


def request_params(method: str, uri: str, position: Position | None) -> dict[str, Any]:
    text_document = {"uri": uri}
    if method == "documentSymbol":
        return {"textDocument": text_document}
    if method == "inlayHint":
        return {
            "textDocument": text_document,
            "range": {
                "start": {"line": 0, "character": 0},
                "end": {"line": 1000000, "character": 0},
            },
        }
    if position is None:
        raise AssertionError(f"{method} request needs an 'at' marker")
    params = {
        "textDocument": text_document,
        "position": {"line": position.line, "character": position.character},
    }
    if method == "references":
        params["context"] = {"includeDeclaration": True}
    return params


def lsp_method(method: str) -> str:
    names = {
        "completion": "textDocument/completion",
        "definition": "textDocument/definition",
        "documentHighlight": "textDocument/documentHighlight",
        "documentSymbol": "textDocument/documentSymbol",
        "hover": "textDocument/hover",
        "inlayHint": "textDocument/inlayHint",
        "references": "textDocument/references",
        "signatureHelp": "textDocument/signatureHelp",
    }
    try:
        return names[method]
    except KeyError as exc:
        raise AssertionError(f"unsupported fixture request method '{method}'") from exc


def assert_request_result(
    method: str, result: Any, expect: dict[str, Any], source: FixtureSource
) -> None:
    for expected in expect.get("contains", []):
        expect_contains(result, expected, method)

    if method == "definition":
        assert_definition(result, expect, source)
    elif method == "hover":
        assert_hover(result, expect)
    elif method == "completion":
        assert_completion(result, expect)
    elif method == "signatureHelp":
        assert_signature_help(result, expect)
    elif method == "documentSymbol":
        assert_document_symbols(result, expect)
    elif method in {"documentHighlight", "references"}:
        assert_marker_ranges(result, expect, source, method)
    elif method == "inlayHint":
        assert_inlay_hints(result, expect, source)


def run_fixture(client: LspClient, spec_path: pathlib.Path) -> list[str]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    source_path = spec_path.parent / spec["source"]
    source = parse_marked_source(source_path)
    uri = source_path.resolve().as_uri()
    diagnostics = client.open_document(uri, source.text)
    failures: list[str] = []
    name = spec.get("name", spec_path.stem)

    try:
        expect_diagnostics(diagnostics, spec.get("diagnostics"), name)
    except AssertionError as exc:
        failures.append(str(exc))

    for request_spec in spec.get("requests", []):
        request_name = request_spec.get("name", request_spec["method"])
        method = request_spec["method"]
        marker_name = request_spec.get("at")
        position = None
        if marker_name is not None:
            position = source.markers.get(marker_name)
            if position is None:
                failures.append(f"{request_name}: unknown marker '{marker_name}'")
                continue
        try:
            result = client.request(
                lsp_method(method), request_params(method, uri, position)
            )
            assert_request_result(
                method, result, request_spec.get("expect", {}), source
            )
            print(f"  PASS: {name}: {request_name}")
        except Exception as exc:
            failures.append(f"{request_name}: {exc}")
            print(f"  FAIL: {name}: {request_name}")

    return failures


def find_specs(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(root.rglob("*.json"))


def public_compiler_version(blorp: str, cwd: pathlib.Path) -> str:
    completed = subprocess.run(
        [blorp, "--version"],
        cwd=str(cwd),
        check=True,
        capture_output=True,
        text=True,
    )
    first_line = completed.stdout.splitlines()[0] if completed.stdout else ""
    prefix = "blorp "
    if not first_line.startswith(prefix) or len(first_line) == len(prefix):
        raise LspError(f"unexpected public compiler version output: {first_line!r}")
    return first_line[len(prefix) :]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("blorp", help="Path to the blorp executable")
    parser.add_argument(
        "fixture_root",
        nargs="?",
        default="tests/lsp/fixtures",
        help="Directory containing LSP fixture specs",
    )
    args = parser.parse_args()

    cwd = pathlib.Path.cwd()
    fixture_root = pathlib.Path(args.fixture_root)
    specs = find_specs(fixture_root)
    if not specs:
        print(f"error: no LSP fixture specs found under {fixture_root}", file=sys.stderr)
        emit_gate_result("FAIL", 0, 1, 1)
        return 1

    print("== LSP fixture runner ==")
    client: LspClient | None = None
    failures: list[str] = []
    failed_specs = 0
    completed_specs = 0
    cleanup_failed = False
    stderr = ""
    try:
        expected_version = public_compiler_version(args.blorp, cwd)
        client = LspClient(args.blorp, cwd)
        client.initialize(cwd.resolve().as_uri(), expected_version)
        for spec in specs:
            spec_failures = run_fixture(client, spec)
            failures.extend(spec_failures)
            if spec_failures:
                failed_specs += 1
            completed_specs += 1
    except Exception as exc:
        failures.append(str(exc))
        failed_specs += len(specs) - completed_specs
    finally:
        if client is not None:
            try:
                client.close()
            except Exception as exc:
                failures.append(f"LSP cleanup failed: {exc}")
                cleanup_failed = True
            stderr = client.stderr_text()

    passed = len(specs) - failed_specs
    failed = failed_specs + int(cleanup_failed)
    tests = len(specs) + int(cleanup_failed)
    if failures:
        print("")
        print("Failures:")
        for failure in failures:
            print(f"FAIL: {failure}")
        if stderr:
            print("")
            print("LSP stderr:")
            print(stderr.rstrip())
        print(f"== LSP fixtures: {passed} passed, {failed} failed ==")
        emit_gate_result("FAIL", passed, failed, tests)
        return 1

    print(f"== LSP fixtures: {passed} passed, 0 failed ==")
    emit_gate_result("PASS", passed, 0, len(specs))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
