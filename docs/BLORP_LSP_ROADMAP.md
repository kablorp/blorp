# Blorp LSP Migration Roadmap

## Goal

Replace the OCaml language server with a Blorp-owned server without creating a
second compiler frontend or switching production routing before the replacement
is behaviorally complete.

The migration proceeds in vertical method slices. Each slice owns decoding,
typed state transition, response construction, and focused tests. Shared code is
extracted only after a second method demonstrates the common contract.

## Ownership

The dependency direction is intentionally one-way:

```text
transport framing
    -> JSON-RPC envelope
        -> method codec
            -> typed handler/state transition
                -> compiler service or workspace actor
```

- `lsp_protocol.brp` owns dependency-light request IDs and protocol outcomes.
- `lsp_json_rpc.brp` owns common JSON-RPC envelope validation and encoding.
- `lsp_transport_model.brp` owns framing errors and the effectful frame boundary.
- `lsp_*_model.brp` files own method or lifecycle data without compiler-stage imports.
- `lsp_document_model.brp` owns URI-versioned document events shared by sync codecs,
  the overlay store, and later compiler snapshots.
- `lsp_document_store.brp` owns balanced open semantics and exact-URI overlay lookup;
  codecs cannot mutate its dictionary representation directly, and
  `lsp_workspace.brp` embeds this same store instead of shadowing open text.
- `lsp_workspace_source.brp` owns unique source-layer construction, overlay/discovered
  reconciliation, and exact compiler-input selection without filesystem IO.
- `lsp_workspace.brp` is the serialized pure reducer for document, disk-source, and
  configuration events. It alone advances workspace revisions and configuration epochs.
- Method modules consume decoded envelopes, own JSON-to-model validation, and
  provide pure typed handlers. Raw-body entry points are convenience wrappers,
  not the production routing boundary.
- `lsp_lifecycle_model.brp` owns the opaque lifecycle state and the only legal
  transitions between protocol phases.
- `lsp_lifecycle_dispatch.brp` is the production protocol gate. It returns
  lifecycle state and exactly one continue, response, or process-exit action.
- `lsp_server_dispatch.brp` composes that gate with operational methods and owns
  the current canonical lifecycle-plus-overlay server state.
- `lsp_architecture.brp` owns the eventual workspace, analysis, and concurrency contracts.
- Transport owns `Content-Length` and stream IO only.
- Compiler analysis must use the production lexer, parser, module loader, and typechecker.

## Slice Contract

A method slice is complete when it:

1. Decodes the JSON-RPC envelope exactly once.
2. Distinguishes requests from notifications in its types.
3. Retains a valid request ID across later validation failures.
4. Represents state changes as typed values rather than hidden mutation.
5. Makes invalid response states unrepresentable, including successful null IDs.
6. Advertises no capability until its production handler is wired.
7. Has Blorp tests for success, malformed input, response obligations, and state preservation.
8. Passes normal and sanitizer execution without importing unrelated compiler stages.
9. Passes leak checking when the slice owns ARC-managed protocol or workspace state.

The production router parses each body once with `decode_lsp_json_rpc_body`,
selects a method from the decoded name, and passes the resulting envelope to
that method's decoder. Every envelope first passes through
`dispatch_lsp_lifecycle_envelope`; only envelopes admitted while running reach
document or query handlers.

## Current State

Last reconciled with the implementation on 2026-08-11.

| Area | Status | Notes |
| --- | --- | --- |
| Protocol foundation | Complete | Request IDs, JSON-RPC envelopes, typed failures, and response encoding |
| Lifecycle | Complete | `initialize`, `initialized`, `shutdown`, `exit`, and lifecycle admission |
| Document synchronization protocol | Complete checkpoint | `didOpen`, `didChange`, `didSave`, and `didClose` codecs and pure transitions; save-triggered disk refresh is not wired or advertised |
| Workspace source model | Complete | Open overlays and discovered sources reconcile under one URI |
| Workspace reducer | Complete checkpoint | Applies document, disk, configuration, and guarded analysis-completion events atomically over indexed stores |
| Syntax diagnostics | Complete checkpoint | Production lexer/parser diagnostics, UTF-16 mapping, and stale-publication guards |
| Workspace compiler analysis | In progress | Shared graph/import policy, deterministic planning, atomic cache/index commit, callable semantic occurrence extraction, and one-graph production compiler-service execution are implemented; remaining symbol categories, cancellation, and scheduling remain |
| Syntax queries | Not started | Document symbols are required for parity; formatting is an optional capability improvement |
| Semantic queries | Not started | Nine semantic methods currently advertised by the OCaml server remain |
| Stdio server and production route | Not started | `blorp lsp` still delegates to the OCaml host |

The completed lifecycle and synchronization behavior is intentionally stricter
than the old OCaml server. Duplicate opens, changes to unopened documents, and
non-newer versions cannot silently replace authoritative text. Do not weaken
those contracts to copy permissive behavior from the transitional server.

The current `lsp_server_dispatch.brp` is a compatibility composition layer. It
owns an `LspDocumentStore` and revision counters so completed protocol slices can
be tested before the workspace actor exists. It is not a second permanent state
model. Remaining work must replace that state with `LspWorkspace`, not keep both
in sync.

## How To Execute The Remaining Roadmap

Implement the checkpoints in order unless a checkpoint explicitly says it may
be parallelized. For every checkpoint:

1. Add a focused failing Blorp test before implementation.
2. Reuse the records and unions in `lsp_architecture.brp`; change those contracts
   first when they cannot represent the required invariant.
3. Keep filesystem IO, compiler execution, and stdio effects outside pure codecs
   and reducers.
4. Run the focused test normally and with `--leak-check` when it retains strings,
   collections, snapshots, or protocol values.
5. Run `scripts/test compiler-blorp` before marking the checkpoint complete.
6. Update the status table and the checkpoint's checkboxes in the same change.

Do not advertise a capability merely because its codec exists. A capability is
implemented only after the real stdio server routes it against canonical
workspace state and its process-level fixture passes.

## Remaining Sequence

```text
R1 indexed workspace storage
 -> R2 shared compiler frontend graph service
 -> R3 deterministic analysis planning
 -> R4 atomic analysis completion
 -> R5 semantic index extraction
 -> R6 production compiler service
 -> R7 scheduler and workspace actor
 -> R8 complete diagnostics
 -> R9 shared query protocol and dispatch
 -> R10 document symbols
 -> R11 hover
 -> R12 navigation
 -> R13 references and highlights
 -> R14 completion
 -> R15 signature help
 -> R16 inlay hints
 -> R17 framed transport and server loop
 -> R18 parity, cutover, and OCaml deletion
```

Formatting can be implemented after R9 and before R17. It is listed separately
because the OCaml server returns an empty result and advertises
`documentFormattingProvider: false`; it is useful, but not a compatibility
blocker.

## R1: URI-Indexed Workspace Storage

**Context:** `LspCompilerWorkspaceSnapshot.sources`, dependency state, and
analysis caches currently expose immutable lists. The behavior is correct, but
editing one document scans and rebuilds workspace-sized lists. Actor wiring
would make this cost part of every keystroke. Indexing belongs behind opaque
types so callers cannot create duplicate URI or artifact entries.

`LspDocumentStore` is already an opaque `Dict` with direct URI lookup. Keep it;
do not include it in this migration or introduce a second document index.

**Inputs:** `LspSourceLayers`, `LspModuleDependencyState`, and
`LspAnalysisCacheSnapshot`.

**Output:** opaque stores with deterministic snapshot iteration and direct key
lookup. Public workspace snapshots may expose ordered lists at compiler-service
boundaries, but reducers must not use those lists as their update representation.

**Sub-tasks:**

- [x] Introduce opaque source and dependency stores keyed by `LspDocumentUri`.
- [x] Introduce an opaque cache indexed by URI or module identity whose lookups
      require the complete phase-specific fingerprint.
- [x] Define constructors that reject duplicate identities rather than using
      last-write-wins behavior.
- [x] Define `get`, `set`, `remove`, and deterministic `values` operations.
- [x] Change `LspCompilerWorkspaceSnapshot` to carry the opaque stores.
- [x] Migrate `lsp_workspace_source.brp` and `lsp_workspace.brp` without changing
      open-overlay, close, removal, or configuration semantics.
- [x] Remove list-search helpers that become unreachable after migration.

**Implemented:** source and dependency keys are derived from their values behind
specialized opaque stores. Cache artifacts are opaque compiler products;
lexed/parsed artifacts derive from one selected workspace source, typed artifacts
validate their canonical module identity and source against the typechecked graph,
and stale fingerprints cannot remove newer entries. `CompilerModuleIdentity` now
provides a lossless length-prefixed storage key so module lookup, replacement, and
removal are direct without conflating equal display names.

**Tests:** constructor duplicate rejection; replacement of one URI; removal;
stable iteration order; open-over-disk selection; hidden disk update; close
revealing disk; configuration replacement; leak checks over repeated immutable
updates.

**Done when:** no accepted document or disk event scans all source or dependency
entries to locate one URI, `LspDocumentStore` remains the sole open-document
index, and existing workspace tests pass unchanged apart from construction
through the new opaque APIs.

## R2: Shared Compiler Frontend Graph Service

**Context:** dependency state deliberately distinguishes unparsed, parsed, and
resolved modules, but canonical graph discovery currently lives in
`stage_12_cli/cli_source_graph.brp`. Reimplementing that behavior under
`stage_12_lsp` would create a second graph builder; importing the CLI module from
the LSP would reverse ownership once the CLI imports the native server. The
shared graph service must therefore be extracted into a compiler-owned module
below both CLI and LSP.

URI suffixes, import strings, and file names are not semantic identities and
must not be used as shortcuts. The service accepts a source provider so the CLI
can read disk while the LSP can select editor overlays from an immutable
snapshot. It owns production parsing, candidate construction, import resolution,
and graph assembly; the LSP only stores its results.

**Prerequisite:** R1.

**Inputs:** compiler source candidates, workspace/package configuration, a
source-provider effect boundary, and production module identity rules.

**Output:** a compiler-owned frontend graph containing finalized parsed modules,
canonical module identities and origins, and exact resolved import edges.

**Required contract correction:** replace the parallel
`dependencies`/`unresolved_import_paths` representation with a typed resolved
edge that retains:

- the importing module identity;
- the requested import path exactly as written, including a package prefix;
- the resolved module identity and origin; and
- an explicit unresolved outcome when no destination exists.

This information must translate directly to `TypecheckResolvedImport` without
joining parallel lists or looking up a destination by display name. Imported
symbol aliases remain in `ParsedProgram`; do not duplicate them in graph edges.

**Sub-tasks:**

- [x] Inventory graph discovery, package configuration, source-provider, and
      graph-result code in `cli_source_graph.brp` and `cli_plan.brp`.
- [x] Define compiler-owned graph types in a stage shared by CLI and LSP; those
      types must import neither `stage_12_cli` nor `stage_12_lsp`.
- [x] Define the source-provider boundary in terms of canonical module
      candidates, not filesystem paths alone.
- [x] Extract production parsing, `module_surface_import_paths`, candidate
      construction, import resolution, cycle handling, and graph assembly into
      the shared service.
- [x] Represent import precedence as one compiler-owned typed lookup plan. CLI
      evaluates filesystem/package lookups and LSP evaluates immutable snapshot
      lookups, but neither client chooses std/package/local precedence.
- [x] Update `LspResolvedModuleDependencies` to store exact typed import-edge
      outcomes rather than separate identity and string lists.
- [x] Adapt the CLI to the shared service first and prove its existing source
      graph behavior is unchanged.
- [x] Adapt an immutable LSP workspace snapshot as a source provider; selected
      open overlays must win without any disk reread.
- [ ] Store parsed and resolved dependency phases in the workspace so failures
      remain explicit and reusable.
- [x] Detect ambiguous or duplicate module identities before planning analysis.
- [x] Derive reverse dependency lookup from resolved identities for invalidation.
- [x] Reset only affected dependency facts when selected source text or
      configuration changes.

**Tests:** unchanged CLI source-graph suites; local import; std import; aliased
package import; native package identity; exact requested-path-to-identity edge;
missing import; ambiguous identity; import cycle; overlay changing an import;
dependency removal; and configuration-root replacement.

**Done when:** CLI and LSP both obtain loaded-module graphs from one compiler-
owned service, a multi-module LSP graph reads open overlays, and no import edge
must be reconstructed from a name or positional list correspondence.

## R3: Deterministic Analysis Planning

**Context:** every revision-advancing transition asks for a new plan because an
older worker result will fail the revision guard even when the edit was only a
document-version change. Planning must combine graph invalidation with cache
misses; otherwise an unrelated revision can permanently lose necessary work.

The first cutover must conservatively reanalyze every transitive dependent of a
source-content change. Whether an edit changed exported semantic types or CTFE
values is known only after typechecking, so the pre-analysis planner cannot use
that distinction. Selective dependent reuse based on a post-analysis semantic
surface fingerprint is a later optimization, not part of migration correctness.

**Prerequisite:** R2.

**Inputs:** `LspWorkspaceTransition`, the R2 resolved dependency graph, selected
source fingerprints, configuration epoch, frontend fingerprint, and existing
caches.

**Output:** one deterministic `LspAnalysisPlan` containing all and only the
targets needed for the transition's snapshot.

**Sub-tasks:**

- [x] Define the frontend fingerprint from compiler options that affect lexing,
      parsing, module surfaces, or typechecking.
- [x] Correct `LspModuleAnalysisFingerprint` so pre-analysis planning does not
      require a not-yet-computed semantic surface fingerprint.
- [x] Construct parse and module-analysis fingerprints only from canonical
      facts already available in the transition snapshot.
- [x] Select directly changed modules and all reverse transitive dependents from
      R2's resolved identity graph.
- [x] Distinguish source-content invalidation from document-identity-only
      invalidation so reusable artifacts survive version-only changes.
- [x] Include targets with no compatible cache entry even when the invalidation
      list is empty.
- [x] Order targets by canonical module identity for reproducible tests and
      compiler requests.
- [x] Return no targets only when every required artifact has a compatible cache
      entry; preserve the transition revision in that empty plan.

**Tests:** first analysis; direct edit; any dependency edit conservatively
reanalyzing transitive importers; version-only edit reusing compatible artifacts;
configuration epoch change; removed module; stale in-flight miss followed by an
unrelated revision; deterministic target ordering; no semantic-surface fact
required before analysis.

**Done when:** pure planner tests account for every revision transition without
calling the compiler or consulting the filesystem.

## R4: Atomic Analysis Completion

**Context:** workers may finish out of order. Publication correctness depends on
checking the scheduled revision, updating caches, replacing module indexes, and
selecting diagnostics in one workspace transition. A check followed by separate
mutation would allow stale results to become visible.

**Prerequisite:** R3. This checkpoint can be developed before the effectful
compiler service by constructing analysis results in tests.

**Inputs:** `LspAnalysisCompletion` and the current `LspWorkspace`.

**Output:** `LspAnalysisCommitted`, `LspCurrentAnalysisFailed`, or
`LspStaleAnalysisDropped`, with a new self-consistent workspace when committed.

**Required contract correction:** replace the wave-wide
`Result[LspAnalysisResult, LspAnalysisFailure]` as the only source of detail with
a per-target outcome union. Every planned target must appear exactly once as a
successful artifact set, parse/frontend failure, typecheck failure, cancellation,
or source-unavailable outcome. Keep a separate whole-wave failure only for a
failure that prevented accounting for targets, such as an internal worker crash.

**Sub-tasks:**

- [x] Implement `lsp_apply_analysis_completion` on `LspWorkspace`.
- [x] Update `LspAnalysisResult` and `LspAnalysisCompletion` to carry one typed
      outcome for every planned target, keyed by target identity.
- [x] Reject duplicate, missing, and unplanned target outcomes as invalid worker
      completions rather than interpreting missing artifacts as parse failures.
- [x] Reject the whole completion when its scheduled revision is not current.
- [x] Validate that every returned artifact belongs to the scheduled plan and
      has matching fingerprints and snapshot identity.
- [x] Replace cache entries and all affected module semantic indexes atomically.
- [x] Compute complete or partial index coverage from actual per-module results.
- [ ] Rebind reusable unversioned artifacts to current document identities
      without rewriting their compiler products.
- [x] Return diagnostics only from a successfully committed current completion.
- [x] Preserve prior good indexes as explicitly stale after a current analysis
      failure; never label them current.

**Tests:** current success; mixed per-target success and parse/typecheck failure;
cancellation; stale success; stale failure; duplicate outcome; missing outcome;
mixed-revision result; unknown target; mismatched artifact ID; cache replacement;
exact partial-coverage reason; repeated immutable commit leak check.

**Done when:** no caller can publish worker output or replace semantic indexes
without passing through this reducer operation.

## R5: Semantic Index Extraction

**Context:** navigation and references must share compiler-issued symbol identity.
Searching names in source text cannot distinguish shadowing, overloads, fields,
constructors, imports, or same-named declarations in different modules. The
index extractor must exist before the compiler service can construct a complete
`LspTypedArtifact`, which requires its module index.

**Prerequisite:** production definition-index and typed-graph artifacts. This
pure extractor can be developed with directly constructed compiler artifacts
before R6 wires the effectful compiler service.

**Inputs:** production definition index, typed AST/graph, compiler source spans,
module identities, and semantic artifact ID.

**Output:** one `LspModuleSemanticIndex` per analyzed module and the information
needed to compose an `LspSemanticIndexSnapshot` with explicit coverage.

**Required contract correction:** `LspExportedSymbolId` cannot be only module,
kind, owner, and name because legal overloads would collide. Add a compiler-
issued stable export key whose overload discriminator comes from canonical
semantic declaration identity. Do not invent that discriminator from formatted
type text in the LSP. Compiler definition IDs remain artifact-local and cannot
serve as stable cross-artifact exported identities.

**Sub-tasks:**

- [x] Inventory compiler definition identities for functions, globals, types,
      constructors, traits, methods, fields, parameters, and locals.
- [x] Define the compiler-owned stable export key and prove two same-named
      overloads have distinct keys without using formatted type or implementation
      text. `LspExportedSymbolId` now contains that opaque compiler key.
- [x] Replace traversal-order overload ordinals with alpha-normalized structured
      semantic callable signatures issued by compiler code; LSP code never
      supplies or infers an overload discriminator.
- [ ] Extend production typed artifacts where a source occurrence lacks a
      definition ID or span; do not reconstruct identity in LSP code.
- [x] Emit callable definition entries with both declaration and selection
      ranges. Globals, types, fields, parameters, and locals remain.
- [x] Emit resolved callable reference entries with declaration status and exact
      module ownership. Non-call name occurrences remain.
- [x] Use `LspExportedSymbolId` for public callable identity and
      `LspArtifactLocalSymbolId` for private callable identity within one typed
      artifact. Extend the same rule to remaining symbol categories.
- [ ] Mark unavailable modules with the exact partial-coverage reason.
- [ ] Provide direct lookup by source position and symbol ID behind opaque
      indexes; do not repeatedly scan all entries per query.
- [ ] Keep extraction a pure projection of compiler artifacts so R6 only
      orchestrates it and R4 remains the sole commit boundary.

**Identity inventory:** callable IDs reach typed functions, foreign functions,
implementation methods, and resolved calls. Union constructor IDs reach typed
variants. Trait and implementation IDs currently remain in typecheck
environments rather than their typed declarations. Globals, records, aliases,
fields, parameters, locals, and ordinary name expressions do not yet carry a
resolved definition identity; only call-shaped name expressions retain a
resolved callable. R5 must extend those production artifacts before semantic
navigation can be correct.

**Tests:** local shadowing, same-named exported overloads, record fields with equal names, union
constructors, trait methods, imported aliases, same name in two modules,
implementation-only edit preserving exported identity, missing source span, and
parse/typecheck failure coverage.

**Done when:** `LspTypedArtifact` can be constructed from production compiler
artifacts without name-based identity heuristics, and all navigation/reference
methods can later be implemented as typed index lookups.

## R6: Production Compiler Service

**Context:** the LSP must not become another frontend. This adapter translates
one immutable workspace snapshot into the production loaded-module and graph
typecheck inputs, then translates compiler artifacts back into LSP-owned cache
and diagnostic values. It should call production APIs directly, not serialize
through JSON bridge endpoints.

**Prerequisites:** R2, R3, and R5. R4 supplies the receiving boundary.

**Inputs:** `LspCompilerAnalysisRequest` with selected sources, canonical
dependencies, configuration, fingerprints, targets, and cancellation token.

**Output:** lexed, parsed, and typed artifacts plus per-target diagnostics, all
stamped with the request revision.

**Compiler API checkpoint:** `compiler_typecheck_graph` currently accepts
finalized parsed programs in one pure call. It cannot consume a prior typed
artifact or observe an LSP cancellation token. The first cutover therefore:

- reuses lexed and finalized parsed artifacts where the production request
  already accepts them;
- retains unchanged typed artifacts for queries, but does not seed a new
  typecheck with them; and
- performs cancellation checks at shared graph/module orchestration boundaries,
  never by adding an LSP callback inside inference.

If module-boundary cancellation cannot be expressed through existing production
streaming orchestration, extract a compiler-owned cancellable graph runner used
by both CLI and LSP. Mid-expression cooperative cancellation and incremental
typed-graph reuse are later compiler optimizations.

**Sub-tasks:**

- [x] Add one adapter module beside production frontend orchestration, with LSP
      types only at its outer boundary.
- [x] Convert selected source snapshots into `CompilerSourceFile` and production
      module load candidates without rereading open files from disk.
- [x] Reuse `parse_compiler_source`, `module_surface_for_program`, production
      loaded-module construction, and `compiler_typecheck_graph`.
- [x] Resolve and typecheck the complete relevant graph once per plan, rather
      than typechecking every target as an isolated program.
- [ ] Reuse compatible lexed and finalized parsed artifacts; reuse a typed
      artifact directly only when the whole typed fingerprint remains valid.
- [ ] Do not claim typed-cache reuse inside a new graph typecheck until the
      production typechecker accepts such an artifact through a typed API.
- [x] Preserve useful parsed artifacts and syntax diagnostics when graph
      typechecking fails.
- [x] Convert structured typecheck diagnostics only against the exact source
      snapshot that owns their spans.
- [x] Run the R5 callable index extractor for every successful typed target and retain its artifact
      ID unchanged through the returned `LspTypedArtifact`.
- [ ] Add or reuse compiler-owned cancellation checkpoints at source selection,
      per-module parsing, graph resolution, and module/typecheck orchestration
      boundaries.
- [ ] Return typed failures for unavailable sources and cancellation; source
      unavailability is implemented, while cancellation awaits R7 token state.

**Tests:** single module; local dependency; std dependency; package dependency;
open overlay overriding invalid disk text; syntax failure; missing import;
dependency type error; target type error; parsed cache hit; unchanged typed
artifact reuse; cancellation at each available shared checkpoint; cancellation
during a pure typecheck becoming a stale dropped result; diagnostic UTF-16 range
on non-ASCII source.

**Done when:** one adapter test proves an overlay-aware multi-module program
produces the same typechecked graph and diagnostics as normal compilation, with
no LSP-specific lexer, parser, loader, or typechecker logic.

## R7: Scheduler And Serialized Workspace Actor

**Context:** the pure workspace reducer is the single writer. Compiler work may
run concurrently, but all client events and worker completions must rejoin one
serialized mailbox. Start with the simplest implementation: one actor and at
most one active compiler analysis wave. Add broader concurrency only after
measurement demonstrates a need.

**Prerequisites:** R3-R6.

**Inputs:** lifecycle-admitted client messages, filesystem/configuration events,
analysis completions, and cancellation notifications.

**Output:** updated lifecycle/workspace state, scheduled work, and typed server
messages ready for transport encoding.

**Pending-query policy:** syntax queries answer immediately from the weakest
current artifact. A semantic query with a compatible typed artifact also answers
immediately. Otherwise the actor stores the stamped query by request ID and
attaches it to the current or next analysis wave. Analysis waves do not own one
request ID; several pending requests and background diagnostics may share a wave.
If a new workspace revision supersedes a pending query, the actor completes that
request exactly once with `LspRequestCancelled` rather than silently restamping
it against different text. Cancelling one request removes only that waiter and
cancels shared analysis only when no diagnostics or other waiter still needs it.

**Sub-tasks:**

- [ ] Introduce the composition state that owns `LspLifecycleState`,
      `LspWorkspace`, active analysis metadata, and pending query requests.
- [ ] Replace `LspScheduledAnalysis.request_id` with actor-owned pending-query
      associations so one analysis wave can satisfy any number of requests.
- [ ] Route accepted document notifications through
      `lsp_apply_workspace_event`; remove the compatibility document/revision
      fields from `LspServerState` once all tests use the canonical workspace.
- [ ] Plan analysis after every transition marked `LspAnalysisPlanRequired`.
- [ ] Execute compiler analysis outside the serialized actor loop so a long pure
      typecheck cannot prevent frame reads, edits, cancellations, or shutdown
      from entering the mailbox.
- [ ] Cancel superseded analysis before scheduling its replacement.
- [ ] Assign monotonic cancellation tokens through a named constructor rather
      than using request IDs or revision numbers as tokens.
- [ ] Feed every worker completion back as `LspAnalysisCompletedActorEvent` and
      apply it through R4 before emitting messages.
- [ ] When a running pure typecheck cannot stop cooperatively, mark its token
      cancelled, drop its eventual completion through R4, and retain only the
      newest replacement plan; do not start unbounded stale workers.
- [ ] Implement `$/cancelRequest` lookup for query-bound work; unknown and
      already-completed IDs are harmless no-ops.
- [ ] Guarantee one terminal response for every admitted query across immediate
      success, queued success, analysis failure, cancellation, superseding edit,
      and shutdown.
- [ ] Make `didSave` emit an effect to reload the URI's discovered disk layer;
      its optional unversioned text remains metadata and never replaces a newer
      editor overlay.
- [ ] Apply the completed disk read back through `LspDiskSourceUpdated` so a
      later close reveals the saved disk contents without direct actor mutation.
- [ ] Advertise a save capability only after this effect is wired. Prefer
      `includeText: false`; continue accepting client-supplied text defensively.
- [ ] Define deterministic behavior when shutdown begins with active work:
      cancel it, admit the shutdown response, and publish nothing afterward.

**Tests:** edit while analysis runs; two rapid edits; unrelated document edit;
two queued queries sharing one wave; cancelling one shared waiter; query
superseded by edit; exactly-once response; close/reopen before completion;
configuration change during analysis; save reload hidden by overlay; close after
save revealing disk; shutdown with active work; stale diagnostics never emitted;
actor state leak check.

**Done when:** the compatibility state is gone, there is exactly one owner of
workspace revisions, overlays, pending requests, analysis commits, and
publication decisions, and native save synchronization is capability-honest.

## R8: Complete Workspace Diagnostics

**Context:** syntax diagnostics and publication encoding already work. This
checkpoint replaces document-only syntax work with graph-aware analysis and
publishes the best current diagnostics for every affected open document.

**Prerequisites:** R6 and R7.

**Inputs:** committed current analysis results and client support for versioned
diagnostics.

**Output:** current `textDocument/publishDiagnostics` notifications and guarded
close clears.

**Sub-tasks:**

- [ ] Publish lexer/parser diagnostics when later compiler phases cannot run.
- [ ] Publish located typecheck, declaration, import, and module diagnostics from
      the complete workspace graph.
- [ ] Add structured source spans to remaining compiler diagnostics where the
      compiler has a defensible location; keep truly compiler-wide failures
      explicitly unlocated.
- [ ] Merge diagnostics from phases without duplicating the same underlying
      failure.
- [ ] Publish an empty current list when a previously failing open document
      becomes clean.
- [ ] Clear diagnostics on close only if the URI is still closed when the clear
      is serialized.
- [ ] Include `version` only when the client advertised support.
- [ ] Never publish a diagnostic whose revision, configuration epoch, source
      fingerprint, or open-document version is stale.

**Tests:** imported module error; missing import; dependency fixed by overlay;
dependency error invalidating an importer; parse error becoming a type error;
error becoming clean; close/reopen race; non-versioned client; unlocated
internal diagnostic omission; rapid-edit stale publication regression.

**Done when:** the native actor passes process-independent diagnostics tests for
multi-module workspaces and no analysis path typechecks an open file in
isolation.

## R9: Shared Query Protocol And Snapshot Dispatch

**Context:** all remaining request methods need the same strict JSON-RPC,
`textDocument`, URI, position/range, cancellation, and response behavior. Build
that once before feature logic. The dispatcher chooses the weakest valid
artifact and stamps the query; feature handlers do not access mutable server
state.

**Prerequisite:** R7. R10 syntax queries can use source/parsed snapshots;
semantic methods additionally require R5 and typed artifacts from R6.

**Inputs:** one decoded JSON-RPC envelope and the current workspace snapshot.

**Output:** `LspQuery`, `LspStampedQuery`, then either a typed query result or a
request failure retaining the original request ID.

**Protocol-model checkpoint:** the current architecture records are sketches,
not yet complete LSP result contracts. Before implementing handlers, audit each
against the fields the native server will emit. At minimum, represent document-
symbol children and typed kinds, navigation target and selection ranges,
document-highlight kinds, completion kinds and stable sort data, complete
signature/parameter information, and inlay-hint kind/padding. Carry negotiated
query capabilities, including navigation link support, in the stamped query or
an equally explicit immutable context.

**Sub-tasks:**

- [ ] Add shared decoders for `TextDocumentPositionParams`, document-only params,
      document-range params, and reference context.
- [ ] Replace stringly or incomplete query-result sketches with typed protocol
      models that can encode every field promised by R10-R16.
- [ ] Add an immutable `LspQueryClientCapabilities` projection and stamp it with
      each admitted query; handlers must not reach back into lifecycle state.
- [ ] Reject notification-shaped query methods and malformed positions/ranges
      without losing a valid request ID.
- [ ] Convert UTF-16 positions against the exact selected source snapshot.
- [ ] Stamp admitted queries with workspace revision, document version, and a
      cancellation token inside the actor.
- [ ] Select source, parsed, or typed artifacts according to each handler's
      minimum requirement.
- [ ] Construct `LspSemanticQueryContext` only after typed artifact ID, module
      index artifact ID, and workspace revision agree.
- [ ] Return explicit cancellation, snapshot-unavailable, and
      analysis-incomplete failures; do not encode missing analysis as a normal
      empty semantic result.
- [ ] Add one response encoder per `LspQueryResult` variant and shared JSON-RPC
      error mapping.

**Tests:** result-model encoder coverage for every variant and optional field;
link-support negotiation; malformed params; missing URI; negative position;
surrogate-pair position; unopened URI; stale snapshot; incomplete analysis;
request ID preservation for integer and string IDs; cancellation; correct
null-versus-empty result shape per method.

**Done when:** adding a feature method requires only a small method codec,
feature handler, result encoder, and fixture, with no new server-state path.

## R10: Syntax Queries

### R10a: Document Symbols

**Context:** document symbols need declarations and source ranges, not successful
typechecking. They should remain useful while a function body is incomplete.

**Prerequisite:** R9.

**Sub-tasks:**

- [ ] Decode and route `textDocument/documentSymbol`.
- [ ] Traverse the production `ParsedProgram` and map supported declaration
      kinds to LSP `SymbolKind` numeric values through a typed enum.
- [ ] Use full declaration spans for `range` and identifier spans for
      `selectionRange`.
- [ ] Preserve source order and include nested members only when their source
      ownership is unambiguous.
- [ ] Encode `DocumentSymbol[]` and advertise `documentSymbolProvider` only after
      actor and process routing are wired.

**Tests:** functions, globals, records and fields, unions and variants, traits and
methods, nested declarations, malformed body with recoverable declarations,
UTF-16 identifiers, and the existing public document-symbol fixtures.

**Done when:** symbol results do not depend on typechecking success and match the
public fixture contract.

### R10b: Formatting (Optional Before Cutover)

**Context:** the current OCaml server does not advertise formatting. Native
support should delegate to the production formatter and return one whole-file
edit only when text changes.

**Prerequisite:** R9. This may be implemented any time after R9 without blocking
R11-R18.

**Sub-tasks:**

- [ ] Decode and route `textDocument/formatting` while accepting standard client
      options without letting them alter Blorp's canonical format.
- [ ] Invoke the same formatter entry point as `blorp format` against selected
      overlay text.
- [ ] Return `[]` for already formatted text and one full-document `TextEdit`
      otherwise.
- [ ] Use the exact original document end position for the replacement range.
- [ ] Return the formatter's normal parse failure as a request failure; never
      partially format invalid source.
- [ ] Advertise `documentFormattingProvider` only after its process fixture
      passes.

**Tests:** already formatted, changed formatting, unsaved overlay, empty file,
non-ASCII final line, CRLF input, and parse failure.

**Done when:** LSP formatting output is byte-for-byte the same as `blorp format`
for the same source.

## R11: Hover

**Context:** hover is document-local but semantic. It needs the typed node at a
position and a shared type renderer; it should not have its own inference or
source-token interpretation.

**Prerequisites:** R9, typed artifacts from R6, and R5 position-to-symbol lookup
where the hover is over a named declaration or reference.

**Sub-tasks:**

- [ ] Decode and route `textDocument/hover`.
- [ ] Resolve the smallest typed expression, pattern, declaration, or field span
      containing the requested byte offset.
- [ ] Render types and signatures through the compiler's canonical display
      helpers, including generic parameters and purity.
- [ ] Return the precise source range when available and `None` when no semantic
      node owns the position.
- [ ] Encode Markdown content and advertise `hoverProvider` only after process
      routing is complete.

**Tests:** local, parameter, function, generic function, type, variant, record
field, imported symbol, whitespace, malformed source, and existing hover fixture.

**Done when:** hover output contains no type guessed from source spelling and
matches compiler-rendered types.

## R12: Definition, Declaration, And Type Definition

**Context:** these methods share position-to-symbol resolution and location
encoding but differ in destination semantics. Keep one navigation engine with a
typed destination kind rather than three copied handlers.

**Prerequisites:** R9 and R5.

**Sub-tasks:**

- [ ] Implement one navigation resolver for definition, declaration, and type
      definition destinations.
- [ ] Resolve locals through artifact-local IDs and exported/imported symbols
      through stable exported IDs.
- [ ] Resolve type-definition destinations from the compiler's resolved type,
      including aliases and generic instantiations according to one documented
      policy.
- [ ] Encode `LocationLink[]` when the client advertised link support and
      `Location[]` otherwise.
- [ ] Preserve `originSelectionRange`, target declaration range, and target
      selection range from compiler spans.
- [ ] Return explicit partial coverage when a destination module lacks current
      analysis.
- [ ] Advertise each provider only after its own process fixture passes.

**Tests:** local function, parameter, imported function, aliased import, type
parameter, record field, constructor, trait method, type alias, cross-file target,
link-support negotiation, partial index, and existing navigation fixtures.

**Done when:** the three methods share identity and location machinery while
retaining distinct typed destination rules.

## R13: References And Document Highlights

**Context:** references are workspace-wide; highlights are the current document
projection of the same symbol identity. A text search is incorrect in the
presence of shadowing and field namespaces.

**Prerequisites:** R9 and R5.

**Sub-tasks:**

- [ ] Resolve the symbol under the query position once.
- [ ] Implement workspace reference lookup across current module indexes.
- [ ] Honor `context.includeDeclaration` exactly.
- [ ] Return index coverage with reference locations so partial answers are not
      presented as complete.
- [ ] Implement document highlights by filtering the same symbol's references
      to the query URI and mapping declaration/read/write kinds where compiler
      facts support the distinction.
- [ ] Deduplicate identical locations by semantic identity and range.
- [ ] Advertise `referencesProvider` and `documentHighlightProvider` separately
      after their process fixtures pass.

**Tests:** local shadowing, nested scopes, record fields, imported symbol,
declaration included/excluded, same spelling with different identity,
cross-module references, partial index, and existing references/highlight
fixtures.

**Done when:** references and highlights are two projections of one semantic
index query rather than separate source traversals.

## R14: Completion

**Context:** completion is the broadest query because valid source is often
temporarily incomplete. It should consume the weakest available artifact and
degrade from typed context to parsed/lexed context explicitly, not by catching
compiler failures or re-parsing text with a private grammar.

**Prerequisites:** R9, production parsed/typed artifacts from R6, and stable
semantic candidates from R5.

**Sub-tasks:**

- [ ] Define typed completion contexts for expression, type, import, UFCS/member,
      record literal, and declaration positions.
- [ ] Add compiler-owned cursor context facts if the production parser or typed
      AST cannot expose them without source heuristics.
- [ ] Gather lexical locals, module declarations, imported exports, type names,
      fields, trait methods, variants, and prelude entries from canonical
      artifacts.
- [ ] Apply scope, visibility, expected-type, receiver-type, and purity filters.
- [ ] Define deterministic ranking and deduplication rules with named priorities.
- [ ] Return labels, detail, and insert text without snippets until snippet
      capability negotiation is implemented.
- [ ] Support `.` as the advertised trigger character and ordinary invoked
      completion.
- [ ] Advertise completion only after all existing public completion fixtures
      pass through the native process.

**Tests:** local scope, shadowing, list receiver methods, record receiver fields,
record literal fields, type context, imports, generic functions, pure-call
filtering, incomplete expression, deterministic order, and all completion
fixtures.

**Done when:** completion uses production scope/type facts and remains useful on
the documented incomplete-source cases without duplicating parser logic.

## R15: Signature Help

**Context:** signature help needs the resolved callable plus an argument index at
the cursor. It shares callable identity and type rendering with hover and
completion.

**Prerequisites:** R9, R11's canonical signature renderer, and typed artifacts
from R6.

**Sub-tasks:**

- [ ] Decode and route `textDocument/signatureHelp`.
- [ ] Identify the innermost call containing the cursor and compute the active
      argument from parsed call structure, not comma counting in raw text.
- [ ] Resolve overload and UFCS callable identity through compiler call facts.
- [ ] Render the selected signature with generic substitutions and purity.
- [ ] Return `None` when no callable is defensibly resolved.
- [ ] Advertise `(` and `,` trigger characters only after process tests pass.

**Tests:** first and later arguments, nested calls, UFCS call, generic
instantiation, overload, trailing comma, incomplete call, cursor outside call,
and existing signature fixture coverage.

**Done when:** active parameter and signature come from the same resolved call
artifact used by typechecking.

## R16: Inlay Hints

**Context:** inlay hints are a typed range query. The first implementation should
match current OCaml behavior and stay narrow; do not add a general hint framework
before another hint kind exists.

**Prerequisites:** R9 and typed artifacts from R6.

**Sub-tasks:**

- [ ] Decode and validate `textDocument/inlayHint` ranges.
- [ ] Emit inferred local binding type hints where an explicit annotation is
      absent and the typed AST has an exact insertion position.
- [ ] Filter hints to the requested UTF-16 range.
- [ ] Render labels through the same canonical type renderer as hover.
- [ ] Do not emit redundant hints for explicit types or unresolved/error types.
- [ ] Advertise `resolveProvider: false` only after the native process fixture
      passes.

**Tests:** inferred local, explicit annotation, generic inferred type, destructure
policy, requested-range filtering, non-ASCII source position, error type, and the
existing inlay fixture.

**Done when:** native output matches the supported OCaml hint surface and every
position maps back to an exact typed source location.

## R17: Framed Transport And Production Server Loop

**Context:** protocol modules currently operate on complete body strings. The
production server needs byte-accurate LSP framing and a composition loop, but
framing must not parse JSON or call compiler code. The actor owns state; the
transport owns only reads and writes.

**Prerequisites:** R7-R9. Feature methods may be wired incrementally, but R18
cutover requires all currently advertised methods.

**Runtime prerequisite:** Blorp's public stdin API is line-based and cannot
preserve arbitrary frame bytes or distinguish every partial-read case. Add a
compiler-owned byte-stream primitive before framing, rather than attempting to
reconstruct `Content-Length` bodies with `read_line`. Keep this private to the
compiler unless a separately designed std API is justified.

**Sub-tasks:**

- [ ] Add a compiler-owned raw stdin chunk read and raw stdout byte write with
      typed EOF/read/write outcomes and focused runtime ownership metadata.
- [ ] Test those primitives with embedded NUL, non-ASCII bytes, short reads,
      exact-buffer reads, EOF, and write failure before using them in LSP code.
- [ ] Implement buffered stdin/stdout frame transport for `Content-Length` with
      partial reads and multiple frames in one buffer.
- [ ] Treat header names case-insensitively, reject invalid or conflicting
      lengths, require the header terminator, and read exact body bytes.
- [ ] Serialize writes so response and notification frames cannot interleave.
- [ ] Decode each body exactly once, pass every envelope through lifecycle
      admission, then route document, cancellation, and query messages.
- [ ] Convert typed server messages to JSON bodies before handing them to the
      frame writer.
- [ ] Keep logs off stdout; stderr logging must not affect protocol state.
- [ ] Handle EOF before initialization, after shutdown, and with an incomplete
      frame deterministically.
- [ ] Ensure exit status is 0 only for `exit` after `shutdown`, preserving the
      completed lifecycle contract.
- [ ] Add a direct Blorp CLI entry point that constructs configuration, source
      loader, compiler service, scheduler, actor, and transport.
- [ ] Add a concrete pre-cutover `make blorp-lsp-native` target producing
      `.build/blorp-lsp-native` and a `scripts/test lsp-native` process gate that
      launches that executable, never `./blorp lsp`.

**Tests:** fragmented header/body, two frames in one read, malformed header,
duplicate/conflicting lengths, incomplete body, non-ASCII byte length,
concurrent response/diagnostic ordering, initialize-to-exit process session,
unexpected EOF, and stdout purity.

**Done when:** a test-only native LSP executable can run full framed sessions
without invoking the OCaml host, and `scripts/test lsp-native` supplies the
process evidence required before changing the public route.

## R18: Compatibility, Cutover, And OCaml Removal

**Context:** migration is complete only when the public `blorp lsp` command runs
the native server and the old server can be deleted. A compatibility flag would
prolong two implementations and is not part of the plan.

**Prerequisite:** R17 plus every capability chosen for cutover.

**Required parity surface:**

- lifecycle and full document synchronization, including save-triggered disk
  refresh and an honest save capability;
- version-aware workspace diagnostics;
- hover;
- definition, declaration, and type definition;
- references and document highlights;
- completion with `.` trigger;
- document symbols;
- signature help with `(` and `,` triggers;
- inlay hints without resolve support.

Formatting is required only if the native initialize response advertises it.

**Sub-tasks:**

- [ ] Run all existing public fixtures against the native server without fixture
      exceptions or method-specific OCaml fallbacks through
      `scripts/test lsp-native`.
- [ ] Add process fixtures for declaration, type definition, cancellation,
      shutdown/exit status, stale diagnostics, and multi-module overlays where
      current public coverage is missing.
- [ ] Compare native and OCaml capability objects; advertise only methods whose
      native process fixtures pass.
- [ ] Point `CliCommandLsp` directly at the Blorp server and remove
      `CliOcamlHostLsp` planning/delegation.
- [ ] After route replacement, point `scripts/test lsp` at the public command and
      remove the temporary native executable target/gate rather than maintaining
      two production entry points.
- [ ] Remove the OCaml LSP modules, RPC tests, dune entries, and host dispatch
      branch that become unreachable.
- [ ] Remove stale bridge types and JSON helpers used only by the OCaml LSP.
- [ ] Update CLI, architecture, editor, and test documentation to identify the
      Blorp server as production.
- [ ] Run normal, sanitizer, leak, CLI, LSP fixture, and premerge gates.
- [ ] Exercise VS Code and IntelliJ against a multi-file workspace, including
      rapid edits, cancellation, navigation, completion, and clean shutdown.

**Done when:** `./blorp lsp` starts no OCaml process, all advertised methods pass
process-level tests, no OCaml LSP source remains, and there is no legacy routing
flag or fallback.

## Cutover Gates

Run these before changing the production route:

```bash
make
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
scripts/test cli
scripts/test lsp-native
scripts/test lsp
scripts/premerge-gate
```

Also inspect the initialize response from the native process and verify that its
capability object exactly matches the methods routed by that same process. Unit
tests for codecs or handlers are not sufficient evidence for advertising a
capability.

## Explicit Non-Goals For This Migration

- Incremental `didChange` ranges. Full synchronization remains the advertised
  contract until UTF-16 range application is implemented end to end.
- A second parser, type inferencer, import resolver, formatter, or symbol naming
  scheme under `stage_12_lsp`.
- Concurrent mutation of workspace state or semantic indexes.
- Name-based navigation or references as a temporary fallback.
- Pre-analysis detection of implementation-only dependency edits. The first
  cutover conservatively reanalyzes transitive dependents; semantic-surface
  comparison is a later measured optimization.
- Incremental typechecking seeded from prior typed artifacts or mid-expression
  cancellation until the production typechecker exposes those capabilities to
  all compiler clients.
- Snippet completion, code actions, rename, semantic tokens, workspace symbols,
  or pull diagnostics. Add these after native parity as independent slices.
- An OCaml compatibility mode after cutover.
