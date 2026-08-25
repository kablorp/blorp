# Compiler Priorities

This document records current cross-cutting compiler outcomes. GitHub issues
own individual implementation slices, status, assignees, and completed work.
Architecture and semantic contracts belong in the reference documents linked
from [README.md](README.md).

## 1. Typechecking Migration

The accepted frontend already owns module binding, declaration skeletons,
resolved type parameters, type headers, callable headers, trait topology, and
implementation headers. Those Phase 1-4 products are the authoritative input
to the remaining migration. The next work must replace broad mutable
typechecking state with explicit phase products without creating a second
typechecker or retaining old and new graphs together.

### Current Status

This table describes production behavior, not the existence of preparatory
types or tests.

| Phase | Product | Status | Verified production state |
| --- | --- | --- | --- |
| 1-4 | Indexed, bound, skeleton, type-header, trait, callable, global-header, and implementation-header graphs | Complete | `AcceptedTypecheckGraph` combines accepted implementation headers with the compatible importable graph. Parser-recovery modules cannot contribute accepted semantic inventory. |
| 5 | Completed global headers | Complete | `TypecheckGraphCompletion` separates opaque accepted and recoverable graphs. Accepted graphs contain only completed initializers; recoverable graphs retain exact global/callable dependencies, typed expressions, and structured per-module diagnostics while admitting only healthy modules to accepted body entry. Pending globals reserve identity but never publish `TYPE_VOID`. |
| 6 | Independently checked body artifacts | Not complete | `AcceptedTypecheckModule` still carries full `TypecheckState`; body entry reconstructs imports and local headers in `Env`, then threads one state through every declaration. |
| 7 | Demand-driven CTFE body set | Not complete | CTFE selects dependency modules, typechecks complete dependency programs, and scans every imported typed program for functions and constructors. |
| 8 | Solved body | Not started as a phase product | Inference, metavariable storage, resolution, zonking, and finalization remain owned by the broad inference implementation. |
| 9 | Validated body | Not started as a phase product | Lexical and final-type checks are not represented by an accepted/rejected validation boundary; final typed-program validation still walks the complete program. |
| 10 | Checked graph and codegen-ready graph | Partial | The CLI already projects a successful rich graph and ends that graph's lifetime before Core preparation. `TypecheckedGraph` remains broad, and Core preparation still accepts raw `TypedProgram` values. |

The current-state claims above are anchored by:

- [`headers/callable_headers.brp`](../compiler/src/stage_06_typecheck/headers/callable_headers.brp),
  which distinguishes annotated and pending globals;
- [`decl.brp`](../compiler/src/stage_06_typecheck/decl.brp), which owns
  accepted body-entry adapters, broad body materialization, and final program
  validation;
- [`bridge.brp`](../compiler/src/stage_06_typecheck/bridge.brp), which
  owns full-module typechecking and CTFE dependency preparation;
- [`stage_07_ctfe/context.brp`](../compiler/src/stage_07_ctfe/context.brp),
  which currently collects CTFE functions from complete typed programs;
- [`compile_frontend.brp`](../compiler/src/stage_12_cli/compile_frontend.brp),
  which owns the existing rich-graph lifetime projection; and
- [`graph_prepare.brp`](../compiler/src/stage_08_core_lower/graph_prepare.brp),
  whose Core entry still accepts raw typed programs.

### Cross-Phase Invariants

Every remaining phase must preserve these properties:

- every source definition has one exact identity and one semantic owner;
- generated definitions use explicit generated identity rather than source-name
  or source-order reconstruction;
- invalid or pending headers cannot reach ordinary body checking or Core;
- imported facts come from accepted graph queries, not reparsing or
  importer-owned `Env` reconstruction;
- one body check receives immutable graph facts and owns all of its mutable
  inference state;
- parser recovery artifacts remain available to tools but never become
  accepted semantic declarations;
- diagnostics have deterministic source order independent of body scheduling;
- CTFE and ordinary compilation reuse the same accepted body artifact;
- Core accepts only a codegen-ready refinement, never a recovery graph; and
- a replacement product does not coexist beyond its cutover with the broad
  state or graph it replaces.

Phases 5-10 are ordered dependencies. In particular, Phase 6 must not make body
checking authoritative while inferred global headers still use placeholder
types; Phase 7 must reuse the Phase 6 body facade rather than grow a CTFE-only
typechecker; and Phase 10 must not hide unfinished solving or validation behind
a new graph wrapper.

Parsed source provenance is not itself a compatibility adapter. Source spans,
import syntax, and compile-time-only builtin declarations may remain available
to diagnostics and tools. The migration debt is semantic consumers rematching
raw parsed declarations after an accepted product exists. Today
`TypedParsedDecl(ParsedDecl)` is a broad catch-all, while Core intentionally
recognizes only imports and builtin type declarations as compile-time-only and
rejects other parsed declarations. Replace that catch-all with exact
source-only variants or provenance records during Phases 6 and 10; do not delete
useful source provenance or let it stand in for accepted semantic state.

### Phase 5: Global Initializers And Header Completion

Implementation issue: [Complete Global Initializer Headers](issues/typechecking/phase-05-global-header-completion.md).

**Goal:** infer each unannotated global initializer exactly once and produce an
immutable header outcome in which every accepted global has a real type.

The production boundary is complete. `GlobalHeader` still distinguishes
annotated headers from pre-completion pending initializers, but pending headers
reserve only graph-owned identity. `CompletedGlobalHeaderGraph` is opaque and
contains only successfully checked typed initializers. `TypecheckGraphCompletion`
constructs either an opaque `AcceptedTypecheckGraph` or an opaque
`RecoverableTypecheckGraph`; a partial graph cannot inhabit the accepted type.
Per-module completion failures remain recoverable graph facts and cannot
construct an `AcceptedTypecheckModule` for the failed module.

Target products:

```text
HeaderCompletionOutcome =
    HeaderGraphAccepted(CompletedHeaderGraph)
    HeaderGraphRejected(RecoverableHeaderGraph, diagnostics)
```

`CompletedHeaderGraph` contains no pending value type. A recovery graph may retain
pending and rejected initializer entries for diagnostics and LSP use, but it
cannot satisfy ordinary body checking or codegen refinement.

Implemented slices:

1. **5A: Initializer dependency plan.** Classify annotated and inferred
   globals, direct global references, initializer calls, cross-module
   dependencies, source-order requirements, mutable restrictions, and CTFE
   roots. Build the dependency graph by `GlobalId`, not names. Define cycle
   behavior explicitly: annotated cycles whose types are already known must be
   distinguishable from unresolved inferred cycles, which receive deterministic
   diagnostics. Later CTFE evaluation remains responsible for rejecting value
   dependency cycles that cannot be evaluated.
2. **5B: Restricted initializer context.** Introduce an immutable
   `InitializerCheckContext` containing accepted type/callable facts, the
   module view, the current global identity, and dependency facts. Give each
   initializer fresh local inference state. Do not expose ordinary body graph
   mutation, Core counters, or a `CompletedHeaderGraph`, because that graph is
   this phase's output.
3. **5C: Complete headers once.** Process dependency components in stable
   order, infer every pending initializer once, validate annotations against
   inferred values, and construct accepted inferred headers in a private
   builder. Preserve typed initializers and exact dependencies for CTFE rather
   than re-inferring them later.
4. **5D: Production cutover.** Make body entry, import projection, and CTFE
   scheduling consume `HeaderCompletionOutcome`. Rejected or pending values
   must fail closed before body checking.
5. **5E: Delete and measure.** Pending-global `TYPE_VOID` registration and
   accepted-body re-inference are removed. The accepted-stage profile reports
   completed initializer count as its secondary output, fingerprints exact
   dependency edges, and records initializer checks plus duplicate requests.
   Immutable initializer module contexts are prepared once per module rather
   than once per initializer. Indexed Kahn ordering and iterative Kosaraju SCC
   classification avoid recursive or repeated-scan graph planning.

Required tests:

- annotated and inferred globals in source and reverse dependency order;
- cross-module initializer dependencies and source aliases;
- specified annotated-cycle behavior and rejected unresolved inferred cycles;
- annotation mismatch, recovery, and deterministic diagnostic order;
- one inference run per initializer; and
- proof that pending/rejected headers cannot construct an accepted body context.

Phase 5 is complete only when every accepted global header has a real type,
each initializer is inferred once, CTFE receives the retained typed initializer,
and the `TYPE_VOID` pending-global fallback has been deleted.

### Phase 6: Independent Body Checking

Implementation issue: [Independently Check Every Body](issues/typechecking/phase-06-independent-body-checking.md).

**Goal:** check every function, method, default implementation, and other
body-bearing definition from one immutable context and one fresh body-local
session.

Current production body entry is accepted-graph-aware but not independent.
`AcceptedTypecheckModule` retains `TypecheckState`; body entry reconstructs
import and local declarations in `Env`; and materialization iterates all parsed
declarations while carrying one mutable state. `InferContext` also embeds the
full `TypecheckState`.

Target products:

```text
BodyCheckOutcome =
    BodyCheckAccepted(CheckedBodyArtifact)
    BodyCheckRejected(RecoveredBodyArtifact, diagnostics)
```

`BodyCheckContext` contains the completed header graph, one module view, the
exact body identity/header, and read-only policy. `InferSession` contains only
body-local scopes, metavariables, substitutions, local/resource identities,
diagnostics, expected-type state, and control context. The Phase 6 accepted
artifact is a facade over all checks currently required for acceptance; Phases
8 and 9 later replace its internals without weakening that public contract.

Implementation slices:

1. **6A: State ownership inventory.** Classify every `TypecheckState`,
   `Context`, `Env`, and `InferContext` field as graph immutable, module
   immutable, body local, expression contextual, post-typecheck, or obsolete.
   Record its readers and writers before moving it.
2. **6B: Immutable body queries.** Define the minimum `BodyCheckContext` and add
   exact graph query APIs for types, callables, globals, traits,
   implementations, and module bindings. Do not copy accepted maps into a new
   per-body environment.
3. **6C: Fresh inference session.** Move lexical scopes, metas, substitutions,
   local IDs, resource state, expected return state, loop/debug context, and
   local diagnostics into `InferSession` or precise nested contexts. Replace
   Boolean combinations with variants where invalid combinations exist.
4. **6D: Complete body facade.** Construct `CheckedBodyArtifact` only after all
   inference, finalization, and validation currently required by production
   have succeeded. Represent failure explicitly; never encode rejection as a
   successful body containing `TYPE_VOID`, empty metadata, or a status Boolean.
5. **6E: Vertical cutover.** Migrate ordinary functions first, then methods,
   default methods, foreign/body-adjacent forms, and any remaining initializer
   body. CTFE and ordinary module materialization must call the same facade.
6. **6F: Prove independence.** Check identical bodies in source order, reverse
   order, and a fixed shuffled order. Compare typed output, exact call
   identities, diagnostics after stable aggregation, and graph fingerprints.
7. **6G: Delete and then reorganize.** Remove migrated broad-state fields,
   declaration-registration adapters, and whole-module body entry points. Move
   typed AST or inference helpers into smaller owners only where the new
   dependency direction is acyclic; do not add forwarding modules merely to
   split files.

Required measurements include body-context construction, accepted-graph
queries, environment copies, local symbol operations, meta operations,
typed-node visits, wall time, and peak memory. Include many small independent
bodies plus generic, call-heavy, resource-heavy, concurrent, and deeply nested
bodies.

Phase 6 is complete only when body scheduling order cannot affect semantics,
body APIs cannot mutate graph facts, CTFE and ordinary output share one facade,
and `InferContext` no longer embeds the complete typechecking state.

### Phase 7: Demand-Driven CTFE Body Materialization

Implementation issue: [Materialize CTFE Bodies On Demand](issues/typechecking/phase-07-demand-driven-ctfe.md).

**Goal:** check only bodies reachable from exact CTFE roots, memoize each body
once, and reuse accepted artifacts for ordinary output.

Current dependency selection is module-level. Each selected dependency is
prepared as a complete typed program, after which CTFE scans every imported
program for constructors and functions. The maintained 24-module by 32-function
profile materialized 768 dependency bodies while evaluation reached 24. The
fixture currently models expected reachable and irrelevant counts; it does not
observe actual materialization.

Target products:

```text
BodyWorklist: definition identity -> work state
CtfeBodySet: definition identity -> CheckedBodyArtifact

WorkState = Unseen | Queued | Checking | Accepted | Rejected
```

Implementation slices:

1. **7A: Instrument current behavior.** Add observed counters for requested,
   queued, checked, accepted, reused, and rejected bodies before changing
   scheduling. Update the width/depth fixture to fail when irrelevant width
   increases actual materialization.
2. **7B: Exact deterministic worklist.** Seed from typed global initializer
   roots and key every state by exact callable/global identity. Prevent
   duplicate queue entries by construction and define stable ordering for
   roots and discovered dependencies.
3. **7C: Typed dependency discovery.** Check a queued body through the Phase 6
   facade, traverse resolved call and function-reference metadata, and enqueue
   exact targets. Handle recursion with work state. Dynamic dispatch and
   higher-order calls require explicit typed targets or an explicit
   conservative candidate set; names, source text, and depth limits are not
   correctness mechanisms.
4. **7D: Artifact reuse.** Store each accepted artifact under its identity.
   Ordinary selected-module assembly asks the same store before checking a
   body. Preserve source output order separately from worklist order and sort
   diagnostics by stable module/definition order.
5. **7E: Cut over ownership.** Move CTFE scheduling out of
   `stage_06_typecheck/bridge.brp` into Stage 07. Delete complete dependency
   `TypedProgram` preparation and old imported-program reconstruction once no
   consumer remains. The bridge should orchestrate requests and transport
   results only.

Phase 7 validation must use the existing CTFE profile with the same checksum.
The representative case should check approximately 24 reachable dependency
functions rather than all 768, except for explicitly recorded conservative
dynamic candidates. Record total declarations, queued bodies, body checks,
duplicate requests, header lookups, CTFE evaluations, wall time, and peak
memory. Include a low-CTFE control to catch fixed overhead regressions.

### Phase 8: Constraint Solving And Type Finalization

Implementation issue: [Separate Solving And Type Finalization](issues/typechecking/phase-08-solver-finalization.md).

**Goal:** make it impossible for body-local inference variables or unresolved
facts to escape as a completed typed body.

There is currently no phase boundary between inferred and solved bodies.
Metavariable state, unification, resolution, zonking, dimensions, and final
typed metadata remain internal to the broad inference implementation.

Target internal boundary:

```text
InferredBody -> Result[SolvedBody, BodySolveFailure]
```

`InferredBody`, `SolvedBody`, and `MetaId` are opaque. Only `SolvedBody` can be
passed to Phase 9, while the public Phase 6 facade continues to expose only an
accepted or rejected complete body.

Implementation slices:

1. **8A: Solver inventory.** Locate fresh-meta creation, origins, bindings,
   occurs checks, unification, deferred overloads, dimension solving,
   resolution, zonking, unresolved diagnostics, and every whole-tree
   finalization pass. Preserve algorithms during extraction.
2. **8B: Body-local solver ownership.** Move solver state behind the inference
   session and use opaque `MetaId`. Replace raw cross-domain integers and
   independently mutable lists with one exact indexed representation.
3. **8C: Solved-body constructor.** Resolve every semantic type, value slot,
   call target, pattern fact, dimension, proof, and nested typed node. Perform
   one final recursive meta-freedom check before constructing `SolvedBody`.
4. **8D: Cut over validators.** Make post-inference validation accept only
   `SolvedBody`; preserve a separate solve-failure/recovery artifact for tools.
5. **8E: Measure before optimizing.** Count meta probes, binds, occurs checks,
   resolution-chain visits, and recursive finalization visits. Introduce path
   compression, union-find, or fewer zonk passes only when measurements justify
   the added machinery.

Phase 8 is complete only when no downstream API can accept `InferredBody`, no
meta remains in nested solved facts, diagnostics retain source origins, and
generic, overload, range, callback, and dimension behavior is unchanged.

### Phase 9: Semantic Body Validation

Implementation issue: [Make Semantic Body Validation Explicit](issues/typechecking/phase-09-semantic-validation.md).

**Goal:** represent semantic acceptance explicitly while keeping every safety
check at the earliest phase that has the facts required to perform it well.

Target products:

```text
BodyValidationOutcome =
    BodyAccepted(ValidatedBody)
    BodyRejected(RejectedBody, diagnostics)
```

Keep lexical checks during binding or inference when delaying them would lose
scope facts or degrade diagnostics: assignment legality, local binding,
expected-type constraints, resource availability inside scopes, capture
restrictions, pattern bindings, and loop/control-context rules.

Move or consolidate checks after solving when they depend on final types or
currently rescan the typed tree: declared and callback purity, stable
debug-only call restrictions, match exhaustiveness after pattern resolution,
tail recursion, final resource non-escape, and final typed-body invariants.

Implementation slices:

1. **9A: Rule inventory.** Record every semantic check, current execution
   point, required facts, traversal count, diagnostic order, and recovery
   behavior. This inventory is required before moving a rule.
2. **9B: Structured validation facts.** Introduce precise call/effect,
   assignment, pattern, tail-position, resource, and capture facts only where
   they replace string identity or repeated traversal. Do not create a
   miscellaneous flags record.
3. **9C: Mechanical extraction.** Move one rule family with its tests while
   preserving execution point, source span, diagnostic text, and ordering.
   Delete the previous traversal after each cutover.
4. **9D: Validated-body boundary.** Consume `SolvedBody`, aggregate outcomes in
   stable order, construct `ValidatedBody` only on complete acceptance, and
   construct the Phase 6 accepted facade only from that value. CTFE and Core
   must be unable to accept `RejectedBody`.
5. **9E: Consolidate measured walks.** Count typed-node visits per rule. Share a
   traversal only when fact ownership and diagnostic ordering remain clear;
   document the reason for every retained complete-body walk.

Phase 9 is complete only when accepted and rejected bodies are distinct types,
lexical safety remains early, final-type rules consume stable solved facts,
diagnostic behavior is unchanged, and no redundant typed-tree scan remains
without measurement and justification.

### Phase 10: Checked Graph And Codegen-Ready Graph

Implementation issue: [Separate Checked And Codegen-Ready Graphs](issues/typechecking/phase-10-checked-codegen-graphs.md).

**Goal:** assemble deterministic tool and compiler products without conflating
recoverable typechecking output with valid Core input.

The CLI already projects a successful `TypecheckedGraph` into a smaller
`CliCoreLoweringInput`, allowing the rich graph to die before Core preparation.
Preserve that completed lifetime boundary. The unfinished work is semantic:
`TypecheckedModule` still contains parsed source, `semantic_program`, a second
CTFE-rewritten `typed_program`, diagnostics, errors, import bindings, and a
`ctfe_evaluated` Boolean, while Core preparation accepts raw typed programs.

Target products:

```text
CheckedGraph
Option[CodegenReadyGraph]
```

`CheckedGraph` may contain rejected/recovered artifacts for `check`, lint, LSP,
and diagnostics. `CodegenReadyGraph` is opaque and exists only when every
definition selected for compilation has accepted headers, accepted validated
bodies where required, and accepted CTFE results.

Implementation slices:

1. **10A: Assembly ownership inventory.** Locate typed-module construction,
   diagnostic aggregation, CTFE attachment, selected-module assembly,
   inventories, and every Core entry. Move assembly out of the broad bridge
   only after its inputs are accepted Phase 5-9 products.
2. **10B: Checked graph.** Store explicit header, body, and CTFE outcomes by
   exact identity. Preserve source-faithful recovered information for tools.
   Avoid optional fields whose validity is coupled to status Booleans.
3. **10C: CTFE result attachment.** Keep one authoritative source-faithful body
   artifact and attach evaluated initializer replacements by exact identity.
   Do not retain complete parallel semantic and CTFE-rewritten programs unless
   profiling demonstrates that a sparse replacement/projection is worse.
4. **10D: Codegen refinement.** Define exactly which artifacts the selected
   target requires, validate completeness once, and construct
   `CodegenReadyGraph`. Make Core lowering accept only that type and delete raw
   `TypedProgram` Core entry points.
5. **10E: Consumer cutover.** Route compile/run/test through
   `CodegenReadyGraph`; route check, lint, and LSP through the appropriate
   checked/recovery product. Preserve the existing early CLI lifetime
   projection rather than wrapping and retaining the rich graph.
6. **10F: Delete and measure.** Remove broad `TypecheckedGraph` assembly,
   duplicated full typed programs, CTFE status booleans, and bridge-owned
   semantic reconstruction after all consumers move. Count body checks,
   artifact reuse, graph scans, retained typed nodes, wall time, and peak
   memory.

Phase 10 is complete only when recovery output and Core input are distinct,
Core accepts only `CodegenReadyGraph`, no accepted body/header is recomputed
during assembly, CTFE state is represented explicitly, and bridge code only
orchestrates phase products.

### Verification Matrix

Every slice starts with a focused failing contract and ends with deletion of
the replaced path. “The new product exists” is not a cutover.

| Phase | Fast proof | Required observations |
| --- | --- | --- |
| 5 Globals | Annotated/inferred cross-module dependency graph | initializer runs, dependency probes, header updates, deterministic cycles/diagnostics |
| 6 Bodies | Same body set in source, reverse, and shuffled order | context builds, graph queries/copies, body checks, typed fingerprints, diagnostics |
| 7 CTFE | Existing 24 modules by 32 functions fixture | requested/queued/checked/reused bodies, duplicate requests, CTFE evaluations |
| 8 Solver | Generic, overload, range, callback, and dimension-heavy bodies | meta probes/binds, occurs checks, resolution and zonk visits, meta-freedom |
| 9 Validation | Large nested body with calls, matches, resources, closures, and concurrency | typed-node visits by rule, total validation walks, exact diagnostics |
| 10 Assembly | Mixed accepted/rejected modules plus overlapping CTFE/output roots | artifact reuse, graph scans, retained typed nodes, Core refinement rejection |

Use `benchmarks/compiler_typecheck_phase_profile` for accepted frontend phase
construction, `benchmarks/compiler_ctfe_typecheck_profile` for Phase 7,
`benchmarks/compiler_typecheck_profile` for representative time,
`benchmarks/compiler_typecheck_memory` for memory, and
`benchmarks/compiler_typecheck_name_lookup_profile` for lookup-heavy changes.
Add a new benchmark only when these cannot isolate the phase.

Compiler memory profiles must include the frontend, backend, and artifact
checkpoints documented in [`benchmarks/README.md`](../benchmarks/README.md).
Baseline and candidate runs use the same bootstrap, C compiler, flags, fixture,
and worker configuration. Record raw samples, median, range, checksum,
revision, counters, and peak memory. A slice is incomplete if peak memory merely
moves later because old and replacement products coexist.

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
`compiler/tests/perceus_cleanup_coverage_ledger.tsv`; remove a row only
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
