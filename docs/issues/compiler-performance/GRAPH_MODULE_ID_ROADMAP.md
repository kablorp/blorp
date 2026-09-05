# Graph-Local Module ID Roadmap

**Status:** Issues 46 and 47 retained a measured TypeHeader-only vertical
slice; Issues 48 and 49 were rejected; Issue 50 retained ordinal import
adjacency; Issue 55 retained Stage 04 module/reference reuse by explicit
maintainer decision despite missing its performance gate; Issue 51 is deferred
pending a production catalog consumer

Issue 45's standalone candidate reduced allocations in a narrow indexed-scope
lookup but increased whole-compiler retired instructions by 0.319%, so its
production code was restored. Issue 46 was later reactivated as one combined
replacement-substrate plus TypeHeader consumer slice. That bounded slice
reduced whole-compiler retired instructions by 0.600% and was retained; global
and callable extensions were measured and rejected.

Issue 55 retained graph-local module/reference IDs across the Stage 04 to Stage
06 handoff and removed the first descriptive reconstruction boundary. Exact
direct/replay behavior was green, but a matched whole-compiler comparison
improved retired instructions by only 0.0154%, below its predeclared 0.10%
gate, with noisy elapsed regression. The maintainer explicitly retained the
implementation for its architectural reuse value. Follow-up work may consume
the retained graph tables, but must independently clear a predeclared
instruction or allocation gate rather than treating Issue 55 as evidence of a
compiler-wide speedup.

## Objective

After module resolution has established an accepted module graph, address
graph-owned module products with a dense integer rather than repeatedly
carrying and examining canonical paths, origins, and opaque identity variants
throughout Stage 06.

This is normalization within one compiler invocation, not caching. Durable
module identity remains descriptive at resolver, diagnostic, artifact, and LSP
boundaries. A graph-local integer is valid only with the module table that
issued it and must never be serialized or retained across analysis graphs.

## Profile Motivation

The Phase 01-06 self-check at revision `0e25482b` ran:

```bash
blorp/build/_build/blorp-cli/blorp check --no-format blorp/src/main.brp
```

Three clean runs produced byte-identical responses and a median of 28.16
seconds, approximately 458.5 billion retired instructions, and 1.10 GB peak
RSS. Exact function instrumentation reported:

| Operation | Calls |
| --- | ---: |
| `module_identity_rep` | 45,429,898 |
| `module_identities_equal` | 21,752,449 |
| `module_identity_storage_key` | 388,115 |
| `resolved_module_identity_storage_key` | 14,793 |

A native 1 ms sample attributed about 1.8% of samples directly to
`module_identities_equal`. That percentage is not the complete opportunity.
Complex `ModuleIdentity` values are also embedded in type, global,
constructor, callable, trait, implementation, definition, catalog, and
semantic-occurrence identities. Those values participate in persistent
collection keys and ordinary value copies, contributing to string hashing,
opaque-representation access, ARC traffic, and collection work that is not
charged exclusively to the equality helper.

The raw evidence is intentionally ignored build output under:

```text
logs/compiler-through-typecheck-profile-2026-09-03-0e25482b/
```

The measured direct-comparison ceiling is modest. The roadmap is therefore a
performance ratchet: no production slice may merge merely because integer
module handles are architecturally appealing.

## Rejected Representation Sketch

These names describe the representation tested and rejected by Issue 45. They
are retained as experiment context, not as an API specification for downstream
issues.

```blorp
opaque type GraphModuleId = Int

opaque type GraphModuleTable = List[PreparedModule]
```

The table owns the existing prepared modules once. `GraphModuleId` is a dense
index into that list. The current pipeline reconstructs imports from canonical
path strings after the Stage 4 graph is flattened into a typecheck request, so
one narrow canonical-path-to-ID index remains a legitimate graph-construction
and import-binding boundary. Canonical path, origin, display name, source, and
parsed module remain available from the selected prepared module rather than
being copied into another descriptor record.

Prefer reusing the existing `IndexedGraph` prepared-module list as this table
instead of adding a parallel descriptor list. In that shape, `target_id`
selects the target slot, path-resolution indexes store IDs as values, and a
prepared module scope retains `(graph, module_id)` rather than a second module
record. A separate descriptor table is justified only if the implementation
audit proves that the existing module product cannot own the metadata once.

The rejected candidate kept `GraphModuleId` module-private to the indexed graph
owner. Any replacement design would need the same boundary: cross-module
consumers receive a numeric slot only from one narrow primitive that first
validates two provenance-bearing prepared scopes for current structural graph
compatibility. If an opaque integer is boxed or retained in generated C, use
the narrowest stack-valued representation supported by Blorp and document the
language constraint. Do not accept a heap allocation per ID.

## Identity Boundaries

There are two different concepts and the implementation must not conflate
them:

| Concept | Lifetime | Purpose |
| --- | --- | --- |
| `ResolvedModuleIdentity` / `ModuleIdentity` | Durable semantic value | Resolution, duplicate detection, diagnostics, external semantic projection |
| `GraphModuleId` | One accepted/direct typecheck universe | Internal ownership, equality, table addressing, graph edges |

`GraphModuleId(7)` from one graph is unrelated to `GraphModuleId(7)` from
another. The compiler has no process-global mutable interner, and this roadmap
must not introduce one. This means graph-local IDs cannot replace freely
comparable durable nominal identities such as `TypeId` merely by changing an
owner field. Safety comes from construction ownership:

1. IDs are created only by the opaque module-table builder.
2. All graph products containing IDs are created from that same table.
3. In the rejected design, IDs remained inside the indexed graph module. Every
   module-indexed category
   product is inseparably bound to owner provenance in its private opaque
   representation, or to an existing graph-bearing field owned by that same
   module. Its query accepts only the requested `PreparedModuleScope`; inside
   the product's owner module, it obtained a list slot through the candidate's
   private compatibility boundary and used that slot immediately. No
   higher-level module passed a validated integer to
   a separate private authority. Standalone nominal identity retains durable
   `ModuleIdentity`.
4. Before data escapes the graph, for example into an LSP semantic index, the
   compiler projects the durable descriptive identity.
5. Direct-program and compiler-surface identities remain descriptive unless
   they enter a proven graph-owned table; magic negative IDs or path-derived
   hashes are not acceptable substitutes.

## Shared Invariants

Every issue in this roadmap must preserve:

1. canonical-path and module-origin identity semantics;
2. duplicate-module diagnostics, source spans, and help text;
3. import resolution and precedence;
4. target-first and deterministic declaration/definition identity allocation;
5. module, declaration, overload, and diagnostic source order;
6. accepted and recoverable graph behavior;
7. exact local/import visibility and privacy;
8. direct-program, anonymous, stdlib, source-package, native-package, user,
   prelude, and compiler-surface distinctions;
9. byte-identical CLI and typecheck responses;
10. stable semantic identity at LSP and artifact boundaries; and
11. no global mutable state, cross-run cache, hash-as-identity shortcut, or
    fallback to the old representation after a family is cut over.

Assigning graph IDs must not reuse or perturb definition-ID, callable-ID, or
type-variable allocation. Numeric ID stability is not a semantic requirement:
assignment follows the accepted graph's existing validated target/dependency
order, while all observable compiler work preserves its current order.

## Measured And Proposed Order

```text
45 broad graph-local module IDs (rejected)
 |
 v
46 private prepared-scope slot plus TypeHeader integer index (retained)
 |
 v
47 dense TypeHeader module inventory (retained)
 |
 v
48 accepted reusable-environment lookup by compatible scope
 |
 v
49 compatible-scope BoundModule lookup and one measured consumer
 |
 v
50 resolved import adjacency by index-local module ordinal
 |
 v
55 preserve Stage 04 module/reference data through Stage 06

51 declaration catalog module buckets remains independent and may start only
if its production-consumer and cost-share gates pass
```

The original Issue 45 arrow was broken by its rejected experiment. Issue 46's
retained TypeHeader slice instead owns its narrower replacement substrate and
does not reactivate Issue 45's broad API. The issue numbers reflect when the
work was documented. This roadmap is independent of the declaration-authority
roadmap, and every issue must inventory the current representation rather than
assuming the callable or environment shape present when this roadmap was
written.

### Issue 45: Establish graph-local IDs

Build one table per accepted Stage 06 graph and cut over prepared/bound module
ownership, scopes, and the linear prepared-environment lookup to dense IDs.
Stage 4 continues using descriptive identities while it resolves and validates
the graph. Including the known linear environment lookup gives the foundation
an immediate production consumer and a defensible independent ROI gate.

The measured candidate was rejected. See Issue 45's experimental result for
the exact controlled data and review findings.

### Issue 46: Index declaration products by module ID

Replace outer descriptive module keys and repeated owner comparisons in
graph-owned declaration catalog/category indexes with graph-local IDs. Durable
`TypeId`, `GlobalId`, `CallableId`, exported-symbol, and semantic-occurrence
identity remains descriptive and cross-graph comparable. Category queries stay
behind the graph owner and project durable IDs only when their API requires it.

Only the TypeHeader product is implemented. It uses a private scope table slot
and compatibility-checked accessor, not Issue 45's discarded `GraphModuleId`.
Other declaration categories remain descriptive.

### Issue 47: Complete dense products and boundaries

Conditionally replace dictionaries keyed by reconstructed module strings with
lists indexed by whatever accepted replacement substrate guarantees one
bounded slot per module. Keep dictionaries for genuinely sparse or source-name
dimensions.
Delete transitional bridges, audit that no ID escapes its graph, document the
durable-identity boundary, and establish the final cumulative Phase 01-06
result in the same issue so cleanup cannot become a performance-neutral fourth
production step.

The measured implementation converts only the retained TypeHeader product from
an integer dictionary to an exact-length list. All 66 synthetic pairs preserved
their checksum and reduced allocations; production replay removed 2,216
allocations and releases with identical response bytes. Other Issue 46
categories and Issue 45's rejected representation do not exist, and every
additional product still needs its own gate.

### Issue 48: Index reusable module environments by scope

Use the existing target-first `PreparedCanonicalModuleEnvironment` list and
the compatible prepared-scope slot to replace retained-graph linear identity
scans. The existing completion boundary proves exact environment count and
alignment before constructing either accepted or recoverable graph facts;
recoverable global-failure admission remains separate. The issue must add no
second table or dormant module ID.

The measured candidate was rejected. It reduced synthetic lookup work but did
not clear the predeclared production allocation or retired-instruction gate;
the compatible-scope environment index was not retained.

### Issue 49: Address bound modules by prepared scope

Add one narrow compatible-scope selector over the existing bound target and
dependency list, then migrate only callers that already own exact scope
provenance. Identity-only and canonical-path callers remain descriptive. The
pre-edit audit must show that the bounded cutover removes at least 25% of
production `bound_module_graph_find` calls; otherwise no API is retained.

The measured candidate was rejected. It retired the targeted identity scans
and improved synthetic allocation counts, but its production allocation share
was below the issue gate; no compatible-scope bound-module selector remains.

### Issue 50: Index resolved import adjacency by module ordinal

Keep source path and alias dictionaries for import resolution, but conditionally
replace the already-resolved path adjacency with one ordinal list per module.
Dependency-only and all-module indexes own separate ordinal universes. This is
a lower-ceiling candidate and must stop early if the 128-module sentinel does
not improve allocations or retired instructions by Issue 50's predeclared 20%
threshold.

The ordinal adjacency was retained. It removed 34,894 exact production
dependency-path lookups, reduced the 128-module focused sentinel allocations
by 96.59%, and reduced the production graph-preparation interval allocations
by 0.130% with byte-identical output. Whole-compiler retired instructions
improved by 0.0137%, so the result is a bounded visibility win rather than a
compiler-wide speedup claim.

### Issue 55: Preserve Stage 04 resolved module data

The candidate made the accepted Stage 04 frontend graph own one dense module
table and exact source-reference resolution table, then bypassed the first
descriptive Stage 06 reconstruction boundary. Direct/replay semantics were
exact, including repeated imports and reordered resolver outcomes.

The implementation was retained by explicit maintainer decision after matched
production measurement improved retired instructions by only 0.0154% against
a 0.10% gate and did not provide a stable elapsed improvement. The graph-owned
IDs and direct adapter therefore remain available, but removing the remaining
canonical program/surface rewrites and importable indexes would require a
broader binding and CTFE data-flow change with its own measured gate.

### Issue 51: Consolidate declaration catalog module indexes if measured

Measure the cost share of the catalog's eight outer module dictionaries before
editing production. Compare the current shape with one descriptive module
bucket and one dense graph-owned bucket. The issue is rejected without code if
real production catalog work is below its predeclared share or neither strategy
wins representative sparse and mixed workloads. The current catalog is used
only by benchmarks/tests, so Issue 51 remains deferred until Issue 43 or another
accepted milestone retains and queries it in production.

Each issue starts from its immediate accepted parent. Rejection does not create
an API or representation dependency for the next issue: the next agent must
rebase its audit and implementation on the actual retained tree.

## Performance Ratchet

Every issue begins from its immediate parent. Use isolated control and
candidate worktrees built by the same bootstrap compiler. The candidate must:

- produce byte-identical responses and semantic checksums;
- reduce the issue's deterministic logical work counters;
- reduce focused allocations or retired instructions;
- reduce either median whole-compiler retired instructions or the issue's
  predeclared exact production allocation/release metric; an instruction
  reduction of at least 1% remains preferred for an independently merged
  production slice;
- when acceptance is allocation-based, keep whole-compiler median retired
  instructions within 0.05% of the immediate baseline; and
- keep median elapsed within 1.0% and median peak RSS within 0.5% of the
  immediate baseline.

If a slice adds the new representation without removing enough old work, do
not merge it. Redesign it or combine it with the next deletion so every merged
checkpoint has a defensible return.

Issue 47's TypeHeader-only conversion is the measured precedent for the
allocation branch: its isolated instruction effect was below resolution, but
it removed an exact 2,216 allocations and releases from production replay,
improved every focused allocation pair, and preserved byte-identical output
within the RSS bound. That result does not authorize another dense product;
each follow-up must satisfy its own predeclared production threshold.

Wall time is supporting evidence. Retired instructions, exact logical counts,
allocator statistics, generated C, and response identity are the primary
decision inputs.

## Common Fast Feedback Loop

During implementation, use this order:

1. Run the directly changed unit suite.
2. Run the focused graph/module-identity behavior suite.
3. Run the smallest synthetic rows: one module, eight modules in a chain, and
   eight modules with dense imports.
4. Check generated C for integer storage/equality and absence of per-ID
   allocation.
5. Run `scripts/compiler-check --changed` only after the small loop is green.
6. Before timing, verify no compiler build, test, benchmark, `sample`, or LLVM
   profile is running.
7. Build matched control/candidate workers, warm each once, then run at least
   three alternating self-check pairs.

The existing fixtures do not yet prove exact owner/edge identity or provide all
allocator fields. Extend the production import-graph harness with an
adjacency-derived owner/edge checksum, explicit table-driven chain, star,
diamond/layered, and dense topologies, allocator output, and distinct graph-
construction versus query windows before using it for acceptance.

The full synthetic matrix independently varies:

- module count: `1, 8, 32, 128`;
- declarations per module: `1, 16, 64`;
- graph topology: chain, star/fan-out, layered/diamond, and dense;
- origin: user, stdlib, source package, and native package where supported;
- exact rejection of canonical-path conflicts across distinct origins; and
- direct-program and compiler-surface cases.

Every row records workload validity, semantic checksum, module and declaration
counts, identity comparisons, storage-key constructions, descriptor reads,
module-index reads/publications, elapsed time, allocations, releases, current
objects/bytes, and peak RSS where available.

All benchmark APIs, runner rows, and issue summaries keep four evidence
classes explicitly tagged and separate:

1. `semantic`: graph dimensions, exact errors, identity/edge checksum, and
   workload validity;
2. `modeled_work`: expected operations derived from fixture inputs;
3. `exact_production`: function/counter observations from actual compiler
   boundaries; and
4. `measured_cost`: elapsed time, retired instructions, allocator fields, and
   RSS.

Modeled operations are never relabeled as exact production counts, and exact
function absence from a saturated instrumentation registry is reported as
unavailable rather than zero.

## Review Discipline

Each issue follows the performance workflow in `AGENTS.md`:

```text
code-optimizer -> implementation -> test-runner -> code-reviewer -> code-optimizer verification
```

Reviewers must explicitly inspect graph-universe safety, preservation of
semantic processing order, direct/compiler-surface behavior, external identity
projection, and the absence of old/new fallback authority.

## Completion Criteria

This roadmap is complete when:

- ordinary graph-owned Stage 06 addressing uses graph-local integers;
- descriptive module facts have one graph-owned table representation;
- dense per-module products use indexed storage;
- paths and origins are consulted only where their semantics or durable
  nominal identity require them;
- no graph-local ID escapes into a persistent LSP/artifact product;
- existing diagnostics and compiler responses remain byte-identical;
- generated C proves stack/integer representation and direct indexing; and
- controlled self-check evidence demonstrates a cumulative win large enough
  to justify the representation change.
