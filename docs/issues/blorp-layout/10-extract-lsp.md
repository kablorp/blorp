# Extract LSP

**Status:** Planned

## Goal

Move protocol, server, workspace, capabilities, and LSP application analysis to
`blorp/src/lsp/`, with mirrored tests under `blorp/test/lsp/`.

## Scope

- Move LSP-owned source and native server code out of compiler stages.
- Move the complete current `tests/lsp` fixture, baseline, transport, process,
  and measurement inventory to `blorp/test/lsp`; discard generated caches.
- Consume compiler-owned semantic facts through the shared frontend-analysis
  boundary from Issue 3.
- Preserve the intentional frontend-only path: LSP analysis must not run Core or
  backend work merely to claim whole-pipeline reuse.
- Keep compiler identity, typed facts, and immutable analysis results on the
  compiler side of the boundary; keep protocol and workspace models LSP-owned.
- If LSP is the second formatter-engine consumer, promote only the shared engine
  to `lib` and record format and LSP as its consumers.

## Required Invariants

- LSP imports no non-library sibling owner, including compiler and format.
- Compiler modules do not import LSP models.
- Snapshot freshness, cancellation, diagnostic ordering, and frontend-only
  latency remain equivalent.

## Validation

Run all LSP analysis, protocol, workspace, capability, server, and public
protocol gates. Profile representative frontend analysis separately from whole
compilation and reject any accidental Core/backend execution.
