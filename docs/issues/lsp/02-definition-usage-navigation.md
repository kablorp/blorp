# Definition Usage Navigation

**Status:** Blocked on a deliberate client-integration decision; workspace-wide
accuracy also depends on Issue 01

## Context

`textDocument/references` already resolves compiler-issued identities from a
single semantic query session. The desired editor interaction is the reverse
navigation surface on a declaration: a singular usage can open directly, while
multiple usages should present a standard location list.

LSP does not redefine Command-click on a definition as “find references.” This
issue must not change `textDocument/definition` or add undeclared
editor-specific behavior.

## Protocol Audit

LSP 3.17 defines `textDocument/codeLens` and the `CodeLens` result shape. A
lens has a source `range` and may carry a `Command` with a title, string
identifier, and arguments. However, the protocol explicitly does not define a
set of well-known command identifiers. In particular, it defines no portable
CodeLens command for either opening one exact location or presenting a list of
references.

`textDocument/references` is a client-to-server request method, not a command
identifier that a client can execute from a lens. `window/showDocument` is a
server-to-client request that can show one URI and optional selection, but a
CodeLens still needs an executable command to cause the server to send that
request, and `window/showDocument` does not present a multiple-location
references UI. `workspace/executeCommand` can route a declared command back to
the server, but that command identifier and its navigation behavior would be a
Blorp/client integration contract rather than standard LSP behavior.

Therefore a portable clickable usage CodeLens cannot be implemented from the
standard protocol alone. A CodeLens without a command is an unresolved lens and
may be completed through `codeLens/resolve`, but the resolved lens still needs a
non-standard command identifier for this navigation. Returning a lens that
remains without a command would be nonfunctional for navigation and is not
accepted as an implementation of this issue.

Protocol references:

- [LSP 3.17 Code Lens Request](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/codeLens.md)
- [LSP 3.17 Command](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/types/command.md)
- [LSP 3.17 Find References Request](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/language/references.md)
- [LSP 3.17 Show Document Request](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/window/showDocument.md)
- [LSP 3.17 Execute Command Request](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/workspace/executeCommand.md)

## Decision Required

Choose one of these explicit integration paths before implementation resumes:

1. Retain standard `textDocument/references` as the portable server surface and
   document an editor keybinding or client contribution that invokes Find
   References from a declaration. This adds no CodeLens capability to the
   server.
2. Support a defined set of editor clients and implement an explicitly
   client-specific CodeLens command alongside those clients. The command name,
   argument schema, one-location behavior, multiple-location behavior, and
   capability negotiation must be owned and tested as a thin client/server
   integration; none may be described as standard LSP behavior.

The second path requires an intentional scope change because the current issue
forbids client-specific commands. No production CodeLens source or tests should
be added until that decision is made.

Choosing the first path closes this issue with documentation or editor-client
contribution work and adds no server CodeLens capability. The remaining server
implementation contract applies only if the second path is explicitly chosen.

## Conditional Server Goal

Add a deterministic definition-usage navigation surface for supported compiler
identities through the explicitly chosen client integration. It must reuse
`SemanticQuerySession` and the references query, distinguish declarations from
usages, and avoid presenting a workspace count unless workspace completeness
has been proven.

Even after a client-integration path is chosen, a workspace-wide label and
command remain blocked on Issue 01's validated workspace target set and
freshness/completeness proof. The current indexed-document extent proves only
coverage across the index producer's declared document set; it must not be
presented as workspace or project coverage.

## Conditional Required Invariants

- Only compiler-projected definitions receive a usage lens.
- Declaration occurrences are excluded from the usage count.
- Zero, one, and many usages have explicit deterministic behavior.
- One usage carries its exact location; many usages invoke the chosen client
  integration with the exact declaration position and deterministic locations.
- Stale, unsupported, or incomplete workspace queries return no misleading
  count and no fabricated locations.
- UTF-8 source offsets are converted through the existing UTF-16 position API.
- Existing definition, references, hover, highlights, and document symbols are
  unchanged.

## Conditional Scope

Only after choosing the second path and recording its client-specific scope,
add a cohesive capability module and matching test module, following the
current `capabilities/<name>.brp` and `<name>_query.brp` organization where both
wire and semantic layers are needed. Extend initialize advertisement, query
admission, and actor dispatch only for a complete, executable integration.

Do not implement rename, workspace discovery, local-variable projection,
client-specific commands beyond the deliberately chosen and documented
integration contract, name-based fallback, or a second semantic query contract.
Do not claim an indexed-open-document count is a workspace count.

## Conditional TDD Contract

Establish failing tests for:

1. capability advertisement and request decoding;
2. zero, one, and multiple non-declaration references;
3. same-name symbols with different semantic identities;
4. deterministic lens and location order;
5. stale and partial coverage producing no misleading lens;
6. unsupported local/method categories failing closed; and
7. UTF-16 positions around non-ASCII source.

Keep tests under `blorp/test/compiler/lsp/capabilities`, with protocol and actor tests
only for their respective boundaries.

## Conditional Validation And Handoff

Run focused semantic-query, capability, initialize, and actor suites,
`scripts/compiler-check --changed`, and `scripts/test lsp`. Report exact pass
counts and whether workspace completeness was available at integration time.
Do not add a private client command or weaken coverage requirements without the
recorded integration decision. Do not merge or push.
