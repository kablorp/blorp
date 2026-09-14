# Compiler Priorities

This is the short map of current cross-cutting outcomes. [Architecture](ARCHITECTURE.md)
and [Ownership Model](OWNERSHIP_MODEL.md) own production contracts;
[`docs/issues/`](issues/README.md) owns the next executable slices. Git and
`benchmarks/results/` own completed work and measurements. Recheck current
code and benchmarks before starting a proposed optimization.

## 1. Finish The Typechecking Product Boundaries

Accepted declaration headers, an `AcceptedSemanticCatalog`, completed global
headers, independently checked body artifacts, and demand-driven CTFE body
checking exist. The remaining goal is to prevent unresolved inference or
recovery facts from entering Core without retaining old and new graphs in
parallel. [Normalized semantic compilation](issues/compiler-performance/NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md)
coordinates exact identity, visibility, body-table, and query cutovers; the
phase issues below own the implementation boundaries.

### Phase 8: Constraint Solving And Type Finalization

[Issue](issues/typechecking/phase-08-solver-finalization.md). Separate an
inferred body from an opaque solved body with body-local metavariable state.
No unresolved type, dimension, call target, or nested typed fact may escape.
Keep source-origin diagnostics and measure solver work before replacing its
algorithms.

### Phase 9: Semantic Body Validation

[Issue](issues/typechecking/phase-09-semantic-validation.md). Make accepted
and rejected body outcomes distinct. Keep lexical safety checks where scope
facts exist; validate final-type rules from solved facts. Preserve exact
diagnostics and remove redundant full-body walks only after counting them.

### Phase 10: Checked Graph And Codegen-Ready Graph

[Issue](issues/typechecking/phase-10-checked-codegen-graphs.md). Preserve
recoverable facts for `check`, lint, and LSP, but let Core accept only an
opaque codegen-ready refinement. Attach CTFE replacements by exact identity,
reuse one source-faithful accepted body, and preserve the existing early
rich-graph lifetime cutoff.

Across these phases: each definition has one owner and exact identity;
pending/rejected facts never enter accepted body checking; every body has
fresh mutable inference state; CTFE reuses accepted body outcomes; diagnostic
order is deterministic; and a replacement product must displace its old
representation at cutover.

## 2. Make Ownership And Core Representation Explicit

Perceus should receive one validated ownership-ready Core form and consume
exact global/local identities, call contracts, and ownership events. It must
not infer an ABI from names or silently accept a new Core variant. Continue
only measured [ownership optimization](issues/compiler-performance/PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md)
tranches and the active [cancellation cleanup](issues/compiler-performance/53-minimize-and-compact-cancellation-cleanup.md)
boundary. Require ownership-event parity, focused runtime/leak and sanitizer
coverage, and production-pass measurements. The normative ABI remains in
[Ownership Model](OWNERSHIP_MODEL.md).

Carry nominal type identity and a closed representation value into Core for
scalar width, signedness, managed/resource classification, Option/Result
layout, and specialization eligibility. Unknown concrete identities should
fail at that boundary. C spelling is a backend projection, not a substitute
for semantic identity.

## 3. Improve Compiler And Generated-Program Performance

Choose work from fresh production profiles and a same-boundary fast loop.
Current candidates include [Core traversal work](issues/compiler-performance/14-reduce-core-program-traversal-work.md),
[token storage](issues/compiler-performance/30-fuse-token-and-token-kind-storage.md),
[match continuations](issues/compiler-performance/52-share-match-continuations.md),
and the admission-gated [nested-record prototype](issues/compiler-performance/NESTED_RECORD_FOLDING_PROTOTYPE_ROADMAP.md).
The [profiling workstream](issues/profiling/README.md) provides the measurement
ladder. Optimize structural work before tuning allocation policy. Compare
output identity as well as time, instructions, allocation, and peak memory;
retain raw results in `benchmarks/results/`.

## 4. Extend Native LSP From Compiler-Owned Facts

Definition, references, hover, document symbols, and highlights have initial
production slices. Keep unsupported capabilities unadvertised. The remaining
[navigation](issues/lsp/02-definition-usage-navigation.md),
[nonmember completion](issues/lsp/03-exact-nonmember-completion.md),
[rename](issues/lsp/04-workspace-rename.md), and
[typed member completion](issues/lsp/05-typed-member-completion.md) work is
blocked on explicit client or compiler semantic-query contracts. Do not
reconstruct visibility, identity, or types in the LSP from source spelling.
Every advertised feature needs process-level protocol fixtures, UTF-16 and
stale-snapshot coverage, deterministic ordering, and bounded output.

## 5. Keep The Developer Feedback Loop Trustworthy

Use a focused test or direct production-pass benchmark while iterating, then
the owning broad gates. Planned improvements to check selection, compiler
build freshness, benchmark comparison, evidence capture, and handoff auditing
live in [agent-workflow issues](issues/README.md#agent-development-workflow).
Do not mistake a docs-only or bootstrap-manifest edit for coverage from
`scripts/compiler-check --changed`.
