# Compiler Priorities

This document records current cross-cutting compiler outcomes. GitHub issues
own individual implementation slices, status, assignees, and completed work.
Architecture and semantic contracts belong in the reference documents linked
from [README.md](README.md).

## 1. Typechecking Phase Products

The accepted frontend already owns module binding, declaration skeletons,
resolved type parameters, type headers, callable headers, trait topology, and
implementation headers. Continue replacing broad mutable typechecking state
with explicit products:

1. Complete definition-owned global initializer headers once, with an explicit
   dependency plan and restricted initializer context.
2. Give function and implementation bodies an independently constructible
   body-check context rather than rebuilding imported declarations in `Env`.
3. Materialize CTFE bodies on demand from exact definition identities.
4. Separate validation and typed-graph construction from body inference.
5. Continue deleting parsed-declaration compatibility adapters as each accepted
   product becomes authoritative. Type declarations now install only from an
   accepted `TypeHeaderGraph`; body-check and CTFE adapters remain in scope.

Required properties:

- every definition has one exact identity and one semantic owner;
- invalid headers cannot reach body inference or Core lowering;
- imported declarations are projected from accepted headers, not reparsed or
  reconstructed per importer;
- parser recovery artifacts never become accepted semantic declarations; and
- each phase product has focused construction, rejection, and provenance tests.

### Phase 5-7 Entry Contracts

The remaining body-check and CTFE migration must preserve these boundaries:

1. Phase 5 body checking receives accepted callable/type headers, one body, and
   its exact dependency identities. It must not rebuild an importer-wide `Env`
   or retain parser recovery state in its result.
2. Phase 6 CTFE starts from exact initializer roots, materializes only their
   transitive body dependencies, and memoizes each accepted body once. Module
   width outside that closure must not increase materialized typed bodies.
3. Phase 7 graph assembly combines accepted headers, typed bodies, diagnostics,
   and CTFE replacements without reparsing or creating a parallel typed graph.
   The CLI then projects the compact Core-lowering input and releases the rich
   typechecked product before Core preparation begins. The source graph retained
   by the command plan is a separate, documented lifetime.

The maintained CTFE width/depth fixture records the expected reachable and
irrelevant body counts while proving that widening a module does not change the
evaluated answer. Phase 6 must add observed materialization counters before the
fixture can prove that irrelevant bodies were not materialized. Compiler memory profiles must include the named
frontend, backend, and artifact checkpoints documented in
[`benchmarks/README.md`](../benchmarks/README.md). A migration slice is not
complete if peak RSS moves later only because old and replacement products are
alive together; the old representation and adapters must be deleted in that
slice.

## 2. Ownership And Perceus Cohesion

Perceus should consume one validated ownership-ready Core form. It should not
repair global identities, infer ABI rules from names, or silently ignore new
Core variants.

Current work:

1. Validate exact global and local identities at ownership ingress.
2. Collect immutable ownership contracts and referenced-global facts once per
   body, including nested lambdas.
3. Replace raw occurrence counting and catch-all legacy conversion with an
   exhaustive ownership-summary algebra.
4. Represent repetition and balancing strategies explicitly.
5. Consolidate borrowed-value normalization when measurements show repeated
   body walks.
6. Narrow contract consumers outside Perceus to an ownership catalog.
7. Split the large pass only after those dependency boundaries are stable.

Completion requires canonical ownership-event parity, focused runtime and leak
coverage, sanitizer coverage, and before/after measurements on the maintained
Perceus fixtures. Optimization work must preserve the ownership ABI in
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md).
The machine-checked counterexample obligations live beside compiler tests in
`compiler/blorp/tests/perceus_cleanup_coverage_ledger.tsv`; remove a row only
when its required regression exists or the ownership contract that required it
has been deliberately superseded.

## 3. Nominal Core Representation

Frontend builtin storage uses exact module/type identity, but some Core and
backend decisions still reconstruct representation from flattened names.

Carry accepted nominal identity and one closed representation value into Core.
Use it for:

- C scalar width, signedness, and function ABI;
- managed/unmanaged and resource classification;
- Option and Result layout;
- closure, collection, and tensor specialization; and
- optimization eligibility.

Unknown concrete identities must fail at the representation boundary. Once all
consumers use the shared index, delete semantic name tables and keep C-name
generation only in backend projection.

## 4. Compiler And Generated-Program Performance

Profile before changing representation or allocation policy. Prefer removing
structural work over allocator tuning.

Highest-value generated-program opportunities:

- ownership-aware record, union, and collection reuse;
- escape analysis and scalar replacement for nonescaping aggregates;
- direct-call conversion and bounded inlining for monomorphic functions;
- collection, string, tensor, and loop fusion; and
- elimination of repeated bounds, layout, and ownership checks.

Highest-value compiler opportunities:

- avoid repeated graph preparation, type resolution, and immutable tree
  rebuilding;
- index exact identities used by repeated lookups;
- keep phase values in process rather than serializing internal boundaries;
- make recursive traversals stack-bounded and reuse unchanged subtrees; and
- keep focused compiler checks substantially shorter than broad integration
  gates.

Performance claims require warm comparable runs, output/checksum parity,
allocation or peak-memory evidence where relevant, and raw results under
`benchmarks/results/`.

## 5. Native LSP Capabilities

The native `blorp lsp` route, lifecycle, full document synchronization,
workspace loading, diagnostics baseline, serialized actor, analysis worker,
and framed stdio transport are established. Unsupported semantic capabilities
must remain unadvertised.

The first semantic query slices are now in production: document symbols,
definition, references, and document-local highlights. Their shared typed admission boundary is also in
place; add the remaining capabilities in this order:

1. Complete pending-query ownership on top of the typed query boundary. The
   synchronous path now creates tokenized `SemanticQueryWork` values carrying
   immutable semantic-index and workspace facts. Add the cancellable worker,
   completion event, and token/snapshot validation only after compiler
   checkpoints can stop or retire query work safely; keep the synchronous path
   as the fallback until then.
2. Extend definition and references over exact compiler identities. The current
   slices now cover imported symbols across provider and qualified modules and
   return `null` when the cursor has no indexed identity. Declaration, type
   definition, and highlights use exact compiler identities rather than source
   spelling.
3. Extend the initial hover slice from indexed declaration names to typed
   compiler-owned rendering. The typecheck stage now supplies the shared
   display projection for callable, named-value, and constructor payload
   declarations; keep completion and signature help separate, and do not infer
   types from source spelling or duplicate typechecking in LSP. Richer nominal
   type bodies and generic bounds remain explicit follow-up display products.
4. Keep document highlights document-local and sorted by protocol range. The
   initial provider covers the currently projected top-level symbol set; extend
   local and type-parameter occurrence projection before widening that contract.
   Do not infer read/write kinds until occurrence facts retain them.
5. Consider formatting, rename, code actions, semantic tokens, and workspace
   symbols only after the shared query path is sound and measured.

Every advertised capability needs process-level fixtures, UTF-16 position
coverage, stale-snapshot cancellation, bounded output, and deterministic result
ordering.

## 6. Developer Feedback

Maintain one clear feedback hierarchy:

```bash
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test
```

Continue unifying local and CI failure artifacts, exact rerun commands, phase
timings, and filtered inspection by stable definition identity. New inspection
tools must query compiler-owned facts rather than reproduce resolution or
ownership logic.

## Completion Discipline

For each issue:

1. Characterize current behavior with the smallest failing or scaling test.
2. Introduce one explicit phase fact or boundary.
3. Cut production consumers over mechanically.
4. Delete the superseded representation, helper, or route in the same change.
5. Run focused checks continuously and broad gates at the ownership boundary.
6. Update reference docs only with the resulting current contract.

Do not preserve completed checklists here. Git history and closed issues are the
project archive.
