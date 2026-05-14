#!/usr/bin/env bash
# Integration test for blorp LSP server.
# Sends real LSP messages over stdio and verifies responses.

set -euo pipefail

BLORP="${1:-./blorp}"
PASS=0
FAIL=0
ERRORS=""

# Absolute URI of a scratch location inside the blorp project — lets the LSP
# walk up to the on-disk std/ dir when resolving embedded module paths.
PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKSPACE_URI="file://${PROJECT_ROOT}"

# ── helpers ──────────────────────────────────────────────────────────

TMPDIR_LSP=$(mktemp -d)
FIFO_IN="$TMPDIR_LSP/in"
FIFO_OUT="$TMPDIR_LSP/out"
mkfifo "$FIFO_IN" "$FIFO_OUT"

# Start LSP server with FIFOs
"$BLORP" lsp < "$FIFO_IN" > "$FIFO_OUT" 2>/dev/null &
LSP_PID=$!

# Open write end (keep FIFO open)
exec 3>"$FIFO_IN"
exec 4<"$FIFO_OUT"

cleanup() {
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    kill "$LSP_PID" 2>/dev/null || true
    wait "$LSP_PID" 2>/dev/null || true
    rm -rf "$TMPDIR_LSP"
}
trap cleanup EXIT

send_msg() {
    local body="$1"
    printf "Content-Length: %d\r\n\r\n%s" "${#body}" "$body" >&3
}

# Read one LSP response (parse Content-Length, read body)
read_response() {
    local header="" len="" body=""
    # Read headers until blank line
    while IFS= read -r header <&4; do
        header="${header%%$'\r'}"
        if [ -z "$header" ]; then
            break
        fi
        case "$header" in
            Content-Length:*)
                len="${header#Content-Length: }"
                ;;
        esac
    done
    if [ -z "$len" ]; then
        echo ""
        return 1
    fi
    # Read exactly len bytes using dd
    body=$(dd bs=1 count="$len" <&4 2>/dev/null)
    echo "$body"
}

check() {
    local name="$1" body="$2" pattern="$3"
    if echo "$body" | grep -q "$pattern"; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="$ERRORS  FAIL: $name (expected: $pattern)\n    got: $body\n"
        echo "  FAIL: $name"
    fi
}

# ── 1. Initialize ────────────────────────────────────────────────────

echo "== Initialize =="
send_msg '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
RESP=$(read_response)
check "returns capabilities" "$RESP" '"capabilities"'
check "has textDocumentSync" "$RESP" '"textDocumentSync"'
check "has hoverProvider" "$RESP" '"hoverProvider":true'
check "has formattingProvider" "$RESP" '"documentFormattingProvider":true'

# Send initialized notification
send_msg '{"jsonrpc":"2.0","method":"initialized","params":{}}'

# ── 2. didOpen with type error → diagnostics ────────────────────────

echo "== Diagnostics (type error) =="
DOC_URI="file:///tmp/test_lsp.brp"
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp.brp","languageId":"blorp","version":1,"text":"x: Int = \"hello\"\n\nfunc main(args: List[String]) -> Int:\n    0\n"}}}'
RESP=$(read_response)
check "publishes diagnostics" "$RESP" '"textDocument/publishDiagnostics"'
check "for correct URI" "$RESP" "$DOC_URI"
check "has non-empty diagnostics" "$RESP" '"message"'

# ── 3. didOpen clean file → empty diagnostics ───────────────────────

echo "== Diagnostics (clean file) =="
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_clean.brp","languageId":"blorp","version":1,"text":"x: Int = 42\n\nfunc main(args: List[String]) -> Int:\n    0\n"}}}'
RESP=$(read_response)
check "publishes diagnostics" "$RESP" '"textDocument/publishDiagnostics"'
check "empty diagnostics array" "$RESP" '"diagnostics":\[\]'

# ── 4. Hover ─────────────────────────────────────────────────────────

echo "== Hover =="
# Hover over 'main' at line 2, col 5 (function declaration)
send_msg '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///tmp/test_lsp_clean.brp"},"position":{"line":2,"character":5}}}'
RESP=$(read_response)
check "hover returns result" "$RESP" '"result"'
check "hover has contents" "$RESP" '"contents"'

# ── 5. Go to Definition ──────────────────────────────────────────────

echo "== Go to Definition =="
# Open a file with a function call that references a defined function
DEF_URI="file:///tmp/test_lsp_def.brp"
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def.brp","languageId":"blorp","version":1,"text":"func add(a: Int, b: Int) -> Int:\n    a + b\n\nfunc main(args: List[String]) -> Int:\n    add(1, 2)\n"}}}'
read_response > /dev/null  # consume diagnostics

# Request definition of 'add' on line 4 col 4 (the call site)
send_msg '{"jsonrpc":"2.0","id":10,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def.brp"},"position":{"line":4,"character":4}}}'
RESP=$(read_response)
check "definition returns result" "$RESP" '"result"'
check "definition has URI" "$RESP" '"uri"'
check "definition has range" "$RESP" '"range"'
check "definition points to line 0" "$RESP" '"line":0'

# Go to definition on a type name in a type annotation
# Source: "record Point {x: Int, y: Int}\n\nfunc main(args: List[String]) -> Int:\n    p: Point = {x = 1, y = 2}\n    0\n"
# Click on 'Point' at line 3 character 8 — should jump to record declaration on line 0
TYPE_URI="file:///tmp/test_lsp_def_type.brp"
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_type.brp","languageId":"blorp","version":1,"text":"record Point {x: Int, y: Int}\n\nfunc main(args: List[String]) -> Int:\n    p: Point = {x = 1, y = 2}\n    0\n"}}}'
read_response > /dev/null  # consume diagnostics

send_msg '{"jsonrpc":"2.0","id":11,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_type.brp"},"position":{"line":3,"character":8}}}'
RESP=$(read_response)
check "definition on type annotation returns URI" "$RESP" '"uri"'
check "definition on type annotation points to record" "$RESP" '"line":0'

# Go to definition on a union variant name in a pattern
# Source: union Shape on line 0-2, func on line 4+, 'Circle' pattern on line 6
VARIANT_URI="file:///tmp/test_lsp_def_variant.brp"
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_variant.brp","languageId":"blorp","version":1,"text":"union Shape:\n    Circle(Float)\n    Square(Float)\n\nfunc area(s: Shape) -> Float:\n    match s:\n        Circle(r): r * r\n        Square(s): s * s\n\nfunc main(args: List[String]) -> Int:\n    _ = area(Circle(1.0))\n    0\n"}}}'
read_response > /dev/null  # consume diagnostics

send_msg '{"jsonrpc":"2.0","id":12,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_variant.brp"},"position":{"line":6,"character":10}}}'
RESP=$(read_response)
check "definition on pattern constructor returns URI" "$RESP" '"uri"'
check "definition on pattern constructor points to union" "$RESP" '"line":0'

# Go to definition on a top-level constant
# Source: MAX: Int = 100 on line 0, reference on line 3
CONST_URI="file:///tmp/test_lsp_def_const.brp"
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_const.brp","languageId":"blorp","version":1,"text":"MAX: Int = 100\n\nfunc main(args: List[String]) -> Int:\n    _ = MAX\n    0\n"}}}'
read_response > /dev/null  # consume diagnostics

send_msg '{"jsonrpc":"2.0","id":13,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///tmp/test_lsp_def_const.brp"},"position":{"line":3,"character":9}}}'
RESP=$(read_response)
check "definition on top-level const returns URI" "$RESP" '"uri"'
check "definition on top-level const points to decl" "$RESP" '"line":0'

# Cross-module: click on an imported function should jump to its source module
# Source imports `get_or` from std/option and calls it.
IMPORT_URI="${WORKSPACE_URI}/tests/.lsp_scratch_import.brp"
send_msg "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"${IMPORT_URI}\",\"languageId\":\"blorp\",\"version\":1,\"text\":\"import:\\n    option { get_or }\\n\\nfunc main(args: List[String]) -> Int:\\n    x: Option[Int] = Some(42)\\n    _ = get_or(x, 0)\\n    0\\n\"}}}"
read_response > /dev/null  # consume diagnostics

# Cursor on `get_or` at line 5 character 10
send_msg "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${IMPORT_URI}\"},\"position\":{\"line\":5,\"character\":10}}}"
RESP=$(read_response)
check "definition on imported name returns URI" "$RESP" '"uri"'
check "definition on imported name points to std/option" "$RESP" 'std/option\.brp'

# Click on the module path INSIDE an import block — should jump to the module file.
IMPORT_MOD_URI="${WORKSPACE_URI}/tests/.lsp_scratch_import_mod.brp"
send_msg "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"${IMPORT_MOD_URI}\",\"languageId\":\"blorp\",\"version\":1,\"text\":\"import:\\n    option { get_or }\\n\\nfunc main(args: List[String]) -> Int:\\n    0\\n\"}}}"
read_response > /dev/null

# Cursor on `option` at line 1 character 5
send_msg "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${IMPORT_MOD_URI}\"},\"position\":{\"line\":1,\"character\":5}}}"
RESP=$(read_response)
check "definition on module name in import block returns URI" "$RESP" '"uri"'
check "definition on module name in import block points to module file" "$RESP" 'std/option\.brp'

# Click on a module alias (L) — should jump to the module file.
ALIAS_URI="${WORKSPACE_URI}/tests/.lsp_scratch_import_alias.brp"
send_msg "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"${ALIAS_URI}\",\"languageId\":\"blorp\",\"version\":1,\"text\":\"import:\\n    list as L\\n\\nfunc main(args: List[String]) -> Int:\\n    _ = L.length([1, 2, 3])\\n    0\\n\"}}}"
read_response > /dev/null

# Cursor on `L` in the import block at line 1 character 12
send_msg "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${ALIAS_URI}\"},\"position\":{\"line\":1,\"character\":12}}}"
RESP=$(read_response)
check "definition on module alias in import block returns URI" "$RESP" '"uri"'
check "definition on module alias in import block points to module file" "$RESP" 'std/list\.brp'

# Cursor on `L` used as alias in code at line 4 character 8
send_msg "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${ALIAS_URI}\"},\"position\":{\"line\":4,\"character\":8}}}"
RESP=$(read_response)
check "definition on module alias at use site returns URI" "$RESP" '"uri"'
check "definition on module alias at use site points to module file" "$RESP" 'std/list\.brp'

# Constructor import: clicking on a constructor listed inside Union(Ctor, ...)
# should jump to the variant's declaration in the source module.
# Uses std/codec — not in the prelude UFCS fallback list, so this exercises
# the constructor-import path specifically.
CTOR_URI="${WORKSPACE_URI}/tests/.lsp_scratch_import_ctor.brp"
send_msg "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"${CTOR_URI}\",\"languageId\":\"blorp\",\"version\":1,\"text\":\"import:\\n    codec { Value(VNull, VBool) }\\n\\nfunc main(args: List[String]) -> Int:\\n    0\\n\"}}}"
read_response > /dev/null

# Cursor on `VNull` at line 1 character 21
send_msg "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${CTOR_URI}\"},\"position\":{\"line\":1,\"character\":21}}}"
RESP=$(read_response)
check "definition on ctor in import block returns URI" "$RESP" '"uri"'
check "definition on ctor in import block points to source module" "$RESP" 'std/codec\.brp'

# Cross-module UFCS: click on a List method used via method-call syntax
# `items.length()` — length is in std/list and is auto-available on prelude types
UFCS_URI="${WORKSPACE_URI}/tests/.lsp_scratch_ufcs.brp"
send_msg "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"${UFCS_URI}\",\"languageId\":\"blorp\",\"version\":1,\"text\":\"func main(args: List[String]) -> Int:\\n    items: List[Int] = [1, 2, 3]\\n    _ = items.length()\\n    0\\n\"}}}"
read_response > /dev/null  # consume diagnostics

# Cursor on `length` at line 2 character 14
send_msg "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"textDocument/definition\",\"params\":{\"textDocument\":{\"uri\":\"${UFCS_URI}\"},\"position\":{\"line\":2,\"character\":14}}}"
RESP=$(read_response)
check "definition on UFCS prelude method returns URI" "$RESP" '"uri"'
check "definition on UFCS prelude method points to a std module" "$RESP" 'std/[a-z]*\.brp'

echo "== Formatting =="
send_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/test_lsp_fmt.brp","languageId":"blorp","version":1,"text":"x:   Int   =   42\n\nfunc main(args: List[String]) -> Int:\n    0\n"}}}'
read_response > /dev/null  # consume diagnostics

send_msg '{"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///tmp/test_lsp_fmt.brp"},"options":{"tabSize":4,"insertSpaces":true}}}'
RESP=$(read_response)
check "formatting returns result" "$RESP" '"result"'
check "formatting has text edits" "$RESP" '"newText"'

# ── 6. didChange → updated diagnostics ──────────────────────────────

echo "== didChange =="
send_msg '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///tmp/test_lsp_clean.brp","version":2},"contentChanges":[{"text":"x: Int = \"oops\"\n\nfunc main(args: List[String]) -> Int:\n    0\n"}]}}'
RESP=$(read_response)
check "didChange triggers diagnostics" "$RESP" '"textDocument/publishDiagnostics"'
check "reports new error" "$RESP" '"message"'

# ── 7. Shutdown ──────────────────────────────────────────────────────

echo "== Shutdown =="
send_msg '{"jsonrpc":"2.0","id":99,"method":"shutdown","params":null}'
RESP=$(read_response)
check "shutdown returns null" "$RESP" '"result":null'

send_msg '{"jsonrpc":"2.0","method":"exit","params":null}'

# Wait for clean exit
wait "$LSP_PID" 2>/dev/null
EXIT_CODE=$?
trap - EXIT
rm -rf "$TMPDIR_LSP"

if [ "$EXIT_CODE" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: clean exit"
else
    FAIL=$((FAIL + 1))
    ERRORS="$ERRORS  FAIL: clean exit (exit code $EXIT_CODE)\n"
    echo "  FAIL: clean exit (code $EXIT_CODE)"
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    printf "$ERRORS"
    exit 1
fi
