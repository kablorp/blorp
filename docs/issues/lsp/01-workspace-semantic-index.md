# Workspace Semantic Index

**Status:** Implemented

## Context

The LSP actor owns immutable `WorkspaceSnapshot` values and rejects stale
analysis completion. The implemented planner declares every selected user
module plus every open document, preserving the selected overlay as compiler
input. Workspace-exhaustive references use a separate proof-derived admission;
the meaning of `IndexedDocumentsSemanticQuery` remains unchanged.

`WorkspaceSnapshotSemanticCompleteness` proves only the immutable declared
source snapshot retained by the workspace. The native process has no filesystem
watcher, so disk freshness advances only through explicit load, create, change,
delete, save-refresh, or configuration events.

## Goal

Analyze a deterministic declared workspace target set, retain explicit outcomes
for every target, and construct an opaque completeness product only when every
declared target is either represented by a current semantic index or by an
explicit, current missing/failure outcome.

Closed files must participate without displacing unsaved open overlays. Disk
create/change/delete and workspace-configuration changes must invalidate the
right target set and must never leave a stale completeness proof usable.

Native execution uses two explicit LSP-local lanes because compiler calls are
not cooperatively interruptible. `WorkspaceIndexAnalysis` retains the complete
declared target set and alone may originate completeness.
`InteractiveDocumentAnalysis` roots one current open document and its frontend-
discovered dependencies on a separate worker; it can publish that document's
current diagnostics/index without waiting for background indexing, but cannot
mint a workspace proof. Same-revision completion order has deterministic
workspace-index precedence, while revision and lane tokens reject stale work.

## Required Invariants

- One query observes one immutable workspace revision.
- Analysis purpose is explicit in plans, requests, schedules, and completions;
  it is never inferred from target count.
- Open document text wins over the discovered disk layer for the same URI.
- Target-set identity is deterministic and based on resolved module identity,
  not path or name guesses.
- A proof constructor verifies declared targets against indexed and explicit
  missing outcomes; callers cannot forge completeness with a boolean.
- Stale, partial, duplicate-identity, or unresolved target sets fail closed.
- Results have deterministic URI/range order independent of discovery order.
- No compiler `Env`, `Scope`, or typed graph escapes into the LSP snapshot.

## Scope

Expected production ownership is limited to:

- `analysis/analysis_planner.brp` and the narrow analysis model needed to carry
  the declared target set and verified completion;
- `analysis/semantic_query.brp` for a workspace extent backed by the opaque
  proof;
- `workspace/source_loader.brp`, `workspace/workspace_source.brp`, and the
  actor/effect path only where closed-source discovery or invalidation needs it;
- matching tests under `blorp/test/compiler/lsp/analysis`, `workspace`, and `server`.

Do not add rename, completion, watcher heuristics, a mutable global index, or a
generic cache framework. If the native process lacks a defensible filesystem
change signal, document and test an explicit refresh boundary and consult the
coordinator before changing the native runtime.

## TDD Contract

Establish failing tests for:

1. a definition and reference split across two closed workspace documents;
2. an unsaved open overlay taking precedence over its disk source;
3. deterministic results after disk create, change, and delete transitions;
4. stale analysis completion being rejected after target-set change;
5. partial or unresolved targets preventing workspace-complete queries;
6. duplicate module identities failing closed;
7. an empty declared workspace receiving an exact empty proof; and
8. deterministic ordering across different discovery orders.

## Validation And Handoff

Run focused analysis/workspace/server suites, `scripts/compiler-check --changed`,
and `scripts/test lsp`. Report exact pass counts, changed files, the proof
constructor invariant, remaining discovery limitations, and reviewer findings.
Do not merge, push, or begin rename.
