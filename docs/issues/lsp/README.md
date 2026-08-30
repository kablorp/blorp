# LSP Improvement Roadmap

This directory defines the implementation contracts for the next native LSP
capabilities. The contracts are intentionally narrower than the user-facing
vision: each issue must preserve exact compiler identity, snapshot freshness,
and honest completeness semantics while adding one independently reviewable
piece.

All work starts from the shared semantic-query contract in
`blorp/src/lsp/analysis/semantic_query.brp`. That contract proves a
query uses one current immutable index snapshot. It supports target-document
and indexed-document extents; it does not currently prove that the index covers
the workspace or that a definition is visible at an arbitrary source position.

## Sequence

The first wave can proceed in separate worktrees:

1. [Workspace semantic indexing](01-workspace-semantic-index.md) establishes a
   validated workspace target set and freshness/completeness proof.
2. [Definition usage navigation](02-definition-usage-navigation.md) adds the
   standard LSP presentation for navigating from definitions to references,
   without changing `textDocument/definition` semantics.
3. [Exact non-member completion](03-exact-nonmember-completion.md) adds only
   candidates whose visibility can be established from compiler-owned facts.

The second wave is dependency ordered:

4. [Workspace rename](04-workspace-rename.md) requires workspace completeness
   and complete occurrence coverage for each supported symbol category.
5. [Typed member and UFCS completion](05-typed-member-completion.md) requires a
   compiler-owned completion-hole and candidate projection.

Workers must not implement a blocked issue opportunistically. Each issue uses
its own `codex/` branch and Codex worktree, follows TDD, updates matching
`blorp/test/compiler/lsp/<subsystem>/` tests, and receives code-reviewer and
test-runner review before commit. Shared compiler representation, identity, or
visibility changes require consultation with the coordinating task first.
