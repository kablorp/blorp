# Graph-Local Module ID Roadmap

**Status:** Issue 46 retained a measured TypeHeader-only vertical slice

Issue 45's standalone candidate reduced allocations in a narrow indexed-scope
lookup but increased whole-compiler retired instructions by 0.319%, so its
production code was restored. Issue 46 was later reactivated as one combined
replacement-substrate plus TypeHeader consumer slice. That bounded slice
reduced whole-compiler retired instructions by 0.600% and was retained; global
and callable extensions were measured and rejected.

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

## Historical Proposed Order

```text
45 establish graph-local module IDs and cut over prepared-module addressing
 |
 v
46 index graph-owned declaration products by module ID
 |
 v
47 replace remaining proven dense products, clean boundaries, and reprofile
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

## Performance Ratchet

Every issue begins from its immediate parent. Use isolated control and
candidate worktrees built by the same bootstrap compiler. The candidate must:

- produce byte-identical responses and semantic checksums;
- reduce the issue's deterministic logical work counters;
- reduce focused allocations or retired instructions;
- reduce median whole-compiler retired instructions, with at least 1% preferred
  for an independently merged production slice; and
- avoid a clear wall-time or peak-RSS regression.

If a slice adds the new representation without removing enough old work, do
not merge it. Redesign it or combine it with the next deletion so every merged
checkpoint has a defensible return.

Issue 47's TypeHeader-only conversion is the documented exception to the
whole-compiler instruction requirement: its isolated effect was below that
measurement's resolution, but it removed an exact 2,216 allocations and
releases from production replay, improved every focused allocation pair, and
preserved byte-identical output without a material RSS regression. This
exception is limited to that measured slice and does not relax the ratchet for
another dense product.

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
