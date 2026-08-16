# Blorp LSP Migration Roadmap

## Goal

Replace the OCaml language server with a Blorp-owned server without creating a
second compiler frontend. Cut over as soon as the Blorp server is a reliable,
capability-honest diagnostics server; add semantic editor features afterward as
independent production slices.

The migration has two milestones:

1. **Native baseline cutover:** lifecycle, full document synchronization,
   workspace source loading, current compiler diagnostics, byte-correct stdio
   framing, and no advertised semantic query providers.
2. **Post-cutover growth:** document symbols, navigation, references, hover,
   completion, signature help, inlay hints, and optional formatting.

Each feature slice owns decoding, typed state transition, response construction,
and focused tests. Shared code is extracted only when a concrete second consumer
demonstrates the common contract.

Protocol behavior targets the published [LSP 3.18 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/)
over JSON-RPC 2.0. The baseline uses static initialize capabilities, UTF-16
positions, and full-document synchronization. A later protocol-version change
must be explicit; do not infer behavior from a client's name or version.

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

Last reconciled with the implementation on 2026-08-14.

| Area | Status | Notes |
| --- | --- | --- |
| Protocol foundation | Complete | Request IDs, JSON-RPC envelopes, typed failures, and response encoding |
| Lifecycle | Complete | `initialize`, `initialized`, `shutdown`, `exit`, and lifecycle admission |
| Document synchronization protocol | Complete checkpoint | `didOpen`, `didChange`, `didSave`, and `didClose` codecs and pure transitions; save-triggered disk refresh is not wired or advertised |
| Workspace source model | Complete | Open overlays and discovered sources reconcile under one URI |
| Workspace reducer | Complete checkpoint | Applies document, disk, configuration, and guarded analysis-completion events atomically over indexed stores |
| Syntax diagnostics | Complete checkpoint | Production lexer/parser diagnostics, UTF-16 mapping, and stale-publication guards |
| Workspace compiler analysis | Complete checkpoint | Shared graph/import policy, canonical workspace source loading and refresh effects, open-root-scoped planning, atomic cache/index commit, category-honest semantic indexes, and one-graph production compiler-service execution are wired through the process actor |
| Native baseline actor | Complete checkpoint | One serialized owner, one serial compiler worker, one active analysis wave, one newest replacement plan, and stale-result suppression |
| Native stdio transport | Complete checkpoint | Bounded byte framing, reactor-safe raw IO, a dedicated writer, bounded terminal drain, and backpressure-safe process exit |
| Syntax and semantic queries | Post-cutover | No query provider blocks the native baseline; every unsupported provider must remain unadvertised |
| Production route | Complete checkpoint | `blorp lsp` executes the Blorp server directly; the OCaml LSP route and implementation have been removed |

The completed lifecycle and synchronization behavior is intentionally stricter
than the old OCaml server. Duplicate opens, changes to unopened documents, and
non-newer versions cannot silently replace authoritative text. Do not weaken
those contracts to copy permissive behavior from the transitional server.

The native process baseline is intentionally capability-small: lifecycle, full
document synchronization, workspace loading, and current parser/typecheck
diagnostics are production behavior. R8 compatibility-dispatch retirement and
R9's broader multi-module diagnostic policy remain cleanup and hardening work;
they must not reintroduce a second process route or advertise semantic providers.

Workspace catalog loading is still interpreted synchronously by the actor during
`initialize`. The measured repository load is short enough for the checkpoint,
but a slow or very large filesystem can delay `exit` until loading returns. Move
that effect to a dedicated loader only with a process regression that controls a
blocked load; do not add a general worker pool or a second mutable workspace
owner. Manual VS Code and IntelliJ cutover checks also remain open below.

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

Keep each numbered checkpoint split at the listed change-set boundaries. A
change set must leave the branch buildable and must not advertise behavior that
the next change set is expected to provide. In particular, do not combine R10
transport work with the R11 route switch: the isolated native process is the
proof that makes cutover and deletion mechanical.

Do not advertise a capability merely because its codec exists. A capability is
implemented only after the real stdio server routes it against canonical
workspace state and its process-level fixture passes.

## Delivery Sequence

```text
R1 indexed workspace storage
 -> R2 shared compiler frontend graph service
 -> R3 deterministic analysis planning
 -> R4 atomic analysis completion
 -> R5 semantic index extraction
 -> R6 production compiler service
 -> R7 workspace source loading
 -> R8 baseline actor and latest-wins analysis
 -> R9 complete baseline diagnostics
 -> R10 raw stdio and framed server process
 -> R11 production cutover and OCaml LSP deletion

POST-CUTOVER:
R12 shared query protocol
 -> R13 document symbols
 -> R14 definition and references
 -> R15 hover
 -> R16 completion
 -> R17 signature help and inlay hints
 -> R18 optional capabilities and measured optimizations
```

R5 semantic identity work may continue in parallel when it does not touch files
owned by the active cutover slice. Parameters, locals, traits, and methods are
not baseline blockers because the baseline advertises no semantic query
providers.

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
- [ ] **Post-cutover R14A:** extend production typed artifacts where a source
      occurrence lacks a definition ID or span. Globals, types, constructors,
      and fields are complete; parameters, locals, traits, and methods remain.
      Do not reconstruct identity in LSP code.
- [x] Emit callable, global, type, constructor, and field definition entries with
      both declaration and selection ranges. Parameters and locals remain.
- [x] Emit resolved callable, global, type, constructor, and field reference
      entries with declaration status and exact module ownership. Other non-call name
      occurrences remain.
- [x] Use `LspExportedSymbolId` for public callable identity and
      `LspArtifactLocalSymbolId` for private callable identity within one typed
      artifact. Globals, types, and constructors now follow the same rule,
      including imported references. Fields follow the same rule; extend it to
      the remaining symbol categories.
- [x] Make module semantic indexes opaque and record exact per-symbol-category
      capabilities so callable-only extraction cannot be mistaken for complete
      semantic coverage.
- [x] Mark unavailable modules with the exact partial-coverage reason.
- [x] Provide direct lookup by source position and symbol ID behind opaque
      indexes; do not repeatedly scan all entries per query.
- [x] Keep extraction a pure projection of compiler artifacts so R6 only
      orchestrates it and R4 remains the sole commit boundary.

**Identity inventory:** callable IDs reach typed functions, foreign functions,
implementation methods, and resolved calls. Global IDs now reach typed global
declarations, local and imported variable symbols, and resolved ordinary name
expressions and assignment targets; value-slot and zonking rewrites preserve
them. Typechecked modules retain a source-semantic typed program before CTFE
materializes immutable global initializers, so references inside those
initializers remain available without changing the runtime-oriented typed
program. Union constructor IDs and source spans reach typed variants, resolved
constructor expressions, and bare or qualified constructor patterns. A compact
compiler-owned side table records source type declarations and annotations while
parsed names, import bindings, and graph-wide definition IDs are simultaneously
available. It covers records, structs, unions, enums, aliases, opaque aliases,
builtin types, nested type expressions, selectively aliased imports, and qualified
imports without reconstructing identity in the LSP. Trait and implementation IDs
currently remain in typecheck environments rather than their typed declarations;
parameters and locals also lack complete source identity. Record field IDs are
reserved with their parent record as owner, carried through generic substitution,
record literals, record updates, ordinary field access, and function-valued field
calls, and preserved from the provider module across selective and qualified
imports. Same-named fields from different providers remain distinct. Private
record fields use artifact-local identities. R5 must extend the remaining
production artifacts before semantic navigation can be complete.

Artifact-local identities carry an explicit compiler-owned symbol category in
addition to the artifact and definition ID. Opaque index constructors therefore
reject a private constructor in a callable-only index, and reject artifact-local
or same-module exported references whose definition is absent from the module
index; exported references owned by a dependency remain valid. Constructor pattern
extraction also verifies that the resolved compiler identity is a constructor
before emitting a semantic reference. Cross-module coverage proves that selective
and qualified constructor calls, nullary values, and patterns all reuse the provider
module's exported identity, while same-named constructors in different provider
modules remain distinct. Selective type aliases and qualified type references
likewise resolve to the provider's exported type identity.

**Baseline tests:** same-named exported overloads, record fields with equal names,
union constructors, imported aliases, same name in two modules,
implementation-only edit preserving exported identity, missing source span, and
parse/typecheck failure coverage. Parameter/local/trait/method identity tests
move with the explicitly deferred R14A work.

**Baseline checkpoint is done when:** `LspTypedArtifact` is constructed from
production compiler artifacts without name-based identity heuristics and its
opaque index reports exact category coverage. Complete navigation coverage is an
R14A exit criterion and does not block R11.

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
artifact or observe an LSP cancellation token. The baseline cutover therefore:

- may rebuild lexed and finalized parsed artifacts when the production request
  cannot accept an existing artifact without a new compiler API;
- retains unchanged typed artifacts for queries, but does not seed a new
  typecheck with them; and
- keeps one active compiler worker and rejects stale completions. Cooperative
  cancellation is not required to preserve correctness at baseline cutover.

If module-boundary cancellation cannot be expressed through existing production
streaming orchestration, extract a compiler-owned cancellable graph runner used
by both CLI and LSP. Mid-expression cooperative cancellation and incremental
typed-graph reuse are later compiler optimizations. The unchecked optimization
tasks below do not block R11.

**Sub-tasks:**

- [x] Add one adapter module beside production frontend orchestration, with LSP
      types only at its outer boundary.
- [x] Convert selected source snapshots into `CompilerSourceFile` and production
      module load candidates without rereading open files from disk.
- [x] Reuse `parse_compiler_source`, `module_surface_for_program`, production
      loaded-module construction, and `compiler_typecheck_graph`.
- [x] Resolve and typecheck the complete relevant graph once per plan, rather
      than typechecking every target as an isolated program.
- [ ] **Post-cutover optimization:** reuse compatible lexed and finalized parsed
      artifacts; reuse a typed artifact directly only when the whole typed
      fingerprint remains valid.
- [ ] **Invariant for future reuse:** do not claim typed-cache reuse inside a
      new graph typecheck until the production typechecker accepts such an
      artifact through a typed API.
- [x] Preserve useful parsed artifacts and syntax diagnostics when graph
      typechecking fails.
- [x] Convert structured typecheck diagnostics only against the exact source
      snapshot that owns their spans.
- [x] Run the R5 semantic index extractor for every successful typed target and
      retain its artifact ID unchanged through the returned `LspTypedArtifact`.
- [ ] **Post-cutover optimization:** add or reuse compiler-owned cancellation
      checkpoints at source selection, per-module parsing, graph resolution,
      and module/typecheck orchestration boundaries.
- [ ] **Post-cutover optimization:** return typed cancellation failures once the
      compiler can observe cancellation. Source unavailability is already a
      typed failure; baseline stale-result rejection belongs to R8.

**Baseline tests:** single module; local dependency; std dependency; package
dependency; open overlay overriding invalid disk text; syntax failure; missing
import; dependency type error; target type error; stale pure-typecheck result;
and diagnostic UTF-16 range on non-ASCII source. Parsed/typed cache reuse and
cooperative-cancellation tests move with their post-cutover optimization tasks.

**Done when:** one adapter test proves an overlay-aware multi-module program
produces the same typechecked graph and diagnostics as normal compilation, with
no LSP-specific lexer, parser, loader, or typechecker logic.

## Completed Change: R7A

Keep the next implementation change limited to the shared project source
catalog. Do not edit actor, transport, initialize capability, or production route
files in this change.

1. Add `test_compiler_project_source_catalog.brp` with temporary projects for a
   nearest `blorp.toml`, configured source package, conflicting alias, std
   override precedence, missing package export, and deterministic normalized
   output that preserves first-match import precedence. Confirm the first
   relevant case fails because no shared API exists.
2. Add `stage_04_modules/project_source_catalog.brp` with compiler-owned request,
   result, issue, std-provider, and package-layout types.
3. Move the generic behavior currently behind
   `find_blorp_config_from_dir`, `source_graph_config`,
   `source_packages_from_config_toml`, package-root resolution, and normalized
   path/config helpers out of `cli_source_graph.brp`. Keep CLI action parsing,
   auto-format decisions, and CLI error rendering in stage 12.
4. Make `cli_source_graph.brp` construct the shared request and adapt the shared
   result into existing CLI plan types. Remove the old duplicate helpers in the
   same change; do not leave forwarding compatibility wrappers without a second
   consumer.
5. Run the new test, `test_compiler_cli_source_graph_context.brp`,
   `test_compiler_cli_frontend_graph_adapter.brp`, `scripts/test compiler-blorp`,
   and `scripts/test cli`.
6. Stop after R7A. R7B begins only after this extraction is reviewed and the CLI
   behavior remains unchanged.

## Native Baseline Contract

R7-R11 are the shortest viable production path. Do not pull a post-cutover
query into this path merely because the OCaml server currently advertises it.

At cutover, the native initialize response advertises exactly:

- `serverInfo.name` and the same build version printed by `blorp --version`;
- UTF-16 positions;
- initial workspace folders with
  `capabilities.workspace.workspaceFolders.supported: true` and
  `changeNotifications` absent;
- `textDocumentSync.openClose: true`;
- full-document changes;
- save notifications with `includeText: false`, backed by R7's disk refresh
  path; and
- no hover, definition, declaration, type-definition, references, highlights,
  completion, document-symbol, signature-help, inlay-hint, or formatting
  provider.

The process must still accept lifecycle messages, synchronized document
notifications, `$/cancelRequest`, and unknown methods correctly. An unsupported
request receives JSON-RPC method-not-found. An unsupported notification is
ignored. There is no method-specific OCaml fallback.

The baseline is viable when editing a multi-file Blorp workspace provides
current parse, import, declaration, and type diagnostics without blocking frame
input or publishing results for stale text. TextMate highlighting remains editor
owned and does not depend on an LSP capability.

## R7: Production Workspace Source Loading

**Purpose:** turn initialization roots and compiler configuration into the exact
`LspDiscoveredSourceSnapshot` values consumed by `LspWorkspace`. Unit tests
currently construct those snapshots directly; the native process has no
production source loader yet.

**Ownership:** filesystem and configuration effects belong in a new effectful
adapter. Import precedence, canonical module identity, package layout, embedded
standard-library lookup, and graph construction remain compiler-owned below the
CLI/LSP boundary. Do not import `stage_12_cli/cli_source_graph.brp` from the LSP.

**Files:**

- Add `stage_04_modules/project_source_catalog.brp` for compiler-owned project
  configuration, package layouts, source discovery policy, and effectful source
  loading currently trapped in `cli_source_graph.brp`.
- Add `stage_12_lsp/lsp_source_loader.brp` as the URI/workspace adapter.
- Extend `compiler/tools/generate_build_sources.brp` so generated
  `stage_01_file_io/embedded_std.brp` exposes deterministic module enumeration;
  do not hand-edit the generated file.
- Extend `lsp_workspace_model.brp` only with typed loading outcomes needed by
  both initialization and save refresh.
- Add `test_compiler_project_source_catalog.brp` for the shared effectful
  boundary.
- Add `test_compiler_lsp_source_loader.brp`.

**Implementation order:**

- [x] Write a failing test that initializes a workspace root containing two
      local modules and proves both become discovered snapshots with canonical,
      distinct identities.
- [x] Move project config discovery, package manifest validation, configured
      package resolution, and source-root normalization from
      `cli_source_graph.brp` into `project_source_catalog.brp`. Give the shared
      records `CompilerProject*` names; no shared type may mention `Cli` or LSP.
- [x] Make `cli_source_graph.brp` adapt `CliAction` into the shared request and
      consume the shared result. Run existing CLI source-graph tests before
      adding the LSP caller, so extraction and new behavior are separate.
- [x] Define `LspSourceLoadRequest` with initialization roots, compiler
      configuration inputs, and one source-discovery policy. Initialization
      precedes document synchronization, so open documents enter through the
      resolved workspace event below rather than being duplicated in this
      request.
- [x] Change `LspInitializeParameters` to retain
      `workspace_folders: Option[List[LspDocumentUri]]` and
      `root_uri: Option[LspDocumentUri]` separately until the loader selects a
      root source. The current merged `workspace_roots` field cannot distinguish
      an absent field from an explicitly empty folder list.
- [x] Replace `LspWorkspaceConfiguration.stdlib_path: String` with a shared typed
      provider that distinguishes embedded std from a validated directory. Carry
      validated `CompilerSourcePackageLayout` values rather than reducing package
      configuration back to unstructured root strings. Empty paths are not
      sentinels for either case.
- [x] Define the effectful boundary as
      `Result[LspSourceLoadResult, LspFatalSourceLoadError]`.
      `LspSourceLoadResult` contains discovered snapshots plus recoverable typed
      loading issues. A fatal error means no authoritative root/catalog can be
      constructed; an unreadable optional source or invalid package entry is a
      recoverable issue, not a half-built success hidden as a fatal error.
- [ ] Carry a source location when the failing compiler phase owns one; do not
      invent a span for workspace-wide IO/configuration errors. Do not encode
      failures as magic module names or empty source text.
- [x] Resolve initialization roots in this order: non-empty
      `workspaceFolders`, then non-null `rootUri`, then the process working
      directory. This intentionally changes the current empty-list behavior, so
      cover `workspaceFolders: []` plus a valid `rootUri` in the decoder and
      loader tests. Normalize and deduplicate overlapping roots before walking.
- [x] Discover `.brp` files deterministically. Sort normalized paths before
      constructing snapshots so source order does not depend on filesystem
      enumeration order.
- [x] Define one `LspSourceDiscoveryPolicy` for traversal exclusions, symlink
      handling, duplicate canonical paths, and workspace containment. Reuse it
      for initialization and refresh instead of scattering path heuristics.
- [x] Define the baseline policy concretely: do not follow directory symlinks;
      canonicalize file symlinks and keep one canonical source; skip only named
      VCS/dependency/build outputs (`.git`, `_build`, `build`, `dist`,
      `node_modules`, `.codex`) through the policy value; and report permission
      failures as typed recoverable issues. Do not skip every hidden directory.
- [x] Select the standard-library provider with the production compiler's
      existing precedence: an explicit caller/environment override such as
      `BLORP_STD`, then a validated project configuration override, then the
      compiler's embedded std. Mark selected modules `CompilerStdlibModule`;
      never infer a checkout-relative `std/` path.
- [x] Extend embedded std generation with a sorted module-name inventory, then
      resolve source through `embedded_std_source`. Do not maintain a second
      hand-written std module list in the LSP.
- [x] Give embedded modules an explicit internal source-URI constructor such as
      `blorp-embedded-std:`. Do not fabricate checkout `file:` paths for embedded
      text. Incoming workspace/document URIs remain `file:`-only at baseline;
      the internal scheme is never accepted from client synchronization.
- [x] Load configured source-package modules and native-package declarations
      through the same package/configuration rules used by CLI compilation.
- [x] Convert file paths to canonical `file:` URIs through one tested helper.
      Reject or explicitly type unsupported URI schemes instead of stripping a
      prefix heuristically.
- [x] Percent-decode incoming file URI paths and percent-encode outgoing paths
      exactly once. Accept an empty or `localhost` authority; reject non-local
      authorities until remote workspaces are designed. Keep platform path rules
      in `path_identity` rather than conditional string rewrites in the LSP.
- [x] Reconcile loaded disk sources through `lsp_source_layers_from_discovered`.
      Existing open overlays remain authoritative and are never reread from
      disk during compiler analysis.
- [x] Add a catalog-backed operation that resolves a `file:` URI opened after
      initialization into its production `CompilerSourceFile` path/module name
      and `CompilerUserModule` identity. Files newly created under a workspace
      root must not require an existing disk snapshot. A file outside every
      initialized root is not guessed into the current project configuration.
      Existing paths are canonicalized at this effect boundary so file or
      directory symlink aliases cannot bypass workspace containment; the pure
      reducer still receives only the resolved value.
- [x] Change the workspace open event to carry that resolved compiler source and
      remove the `compiler_source_file(uri, uri, text)` provisional fallback from
      `lsp_workspace_source.brp`. URI text is not a production module name.
- [x] Implement a save-refresh effect that rereads only the saved URI's disk
      layer, applies `LspDiskSourceUpdated`, and leaves the open overlay selected.
      A later close must reveal the refreshed disk contents.
- [x] Represent deletion between save and refresh as `LspDiskSourceRemoved`.
- [ ] Interpret save refresh serially before dequeuing the next client event for
      the baseline. The actor already assigns an opaque document-effect token
      and admits only its matching completion; the interpreter must enforce the
      corresponding no-dequeue contract. The separate frame reader may continue
      to buffer up to its bounded channel capacity while the read completes.
- [x] Retain the initialize request ID and validated roots while source loading
      runs. Construct the complete `LspWorkspace`, then commit the lifecycle
      transition and send the successful initialize response. On fatal loading
      failure, send one JSON-RPC error with the original ID and retain no
      partially initialized workspace. Emit recoverable issues as one typed
      reporting effect instead of retaining them in ready actor state.
- [ ] Measure cold and warm initialization against the Blorp repository and
      record median and slowest values. Initialization must remain within the
      process fixture's named request timeout. If catalog construction itself is
      too slow, stop R7B and redesign the catalog to load source contents lazily;
      an additional loading state cannot reduce initialize-response latency.
      Never send success or compile against a temporarily incomplete catalog.

**Required tests:**

- local import, relative import, embedded std import, source-package alias,
  source-package internal module, and native-package declaration;
- explicit `BLORP_STD`, project-configured std, and embedded std precedence;
- workspace folders taking precedence over `rootUri`, null roots falling back
  to cwd, overlapping roots, duplicate canonical identities, unreadable file,
  invalid config, and deterministic ordering;
- newly created unsaved file under a root with working imports and no URI-shaped
  module name, plus an out-of-root file being rejected without mutating project
  configuration;
- open overlay winning over disk, save refresh hidden by overlay, close revealing
  saved disk, save after deletion, and non-ASCII path/URI round trip;
- CLI source-graph regression tests after extraction; and
- normal, leak-check, and sanitizer execution of the loader tests.

**Change-set boundaries:**

1. **R7A shared project catalog:** add `project_source_catalog.brp`, migrate the
   CLI adapter, and prove no CLI behavior changes.
2. **R7B LSP initialization loader:** add URI/root conversion, embedded std
   enumeration, deterministic source discovery, and workspace construction.
3. **R7C refresh:** add save/delete disk refresh and overlay reconciliation.

Do not start R8 until R7B can construct a complete workspace without a CLI
import. R7C may land with R8 only if the save capability remains unadvertised
until both are complete.

**Focused gates:**

```bash
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_source_loader.brp
./blorp test --suite compiler/blorp/tests/test_compiler_project_source_catalog.brp
./blorp test --suite compiler/blorp/tests/test_compiler_cli_source_graph_context.brp
./blorp test --leak-check --suite compiler/blorp/tests/test_compiler_lsp_source_loader.brp
./blorp test --sanitize=undefined --suite compiler/blorp/tests/test_compiler_lsp_source_loader.brp
scripts/test compiler-blorp
```

**Exit criteria:** an effectful loader integration test initializes from a
temporary multi-module workspace, preserves an unsaved importer overlay, and
produces the same selected compiler sources and import identities as
`blorp check` without importing a CLI module from `stage_12_lsp`. Process framing
is deliberately deferred to R10.

## R8: Baseline Actor And Latest-Wins Analysis

**Purpose:** establish one serialized owner for lifecycle, workspace state,
analysis scheduling, and outbound messages while keeping compiler work off the
frame-reader path.

**Simplification:** the baseline has no pending semantic queries. It needs only
background diagnostics. Use one analysis worker, at most one active plan, and at
most one retained replacement plan. Do not build a worker pool or general job
scheduler.

**Analysis scope correction:** the source catalog is a resolution candidate set,
not an instruction to typecheck every file. The current planner targets every
catalog source and `lsp_frontend_graph_for_sources` passes no roots to graph
discovery. Before actor wiring, make open documents the explicit graph roots and
publication targets. Their transitive local/std/package imports remain graph
modules, but unopened unrelated files do not enter the graph merely because the
loader discovered them.

**Files:**

- Add `lsp_server_event.brp` for actor input/output unions.
- Add `lsp_server_actor.brp` for the pure state transition and effect commands.
- Add `lsp_analysis_worker.brp` for the single serial compiler worker loop.
- Add `lsp_cancel_request.brp` for the baseline no-op notification boundary used
  by R12's real waiter cancellation.
- Replace compatibility ownership in `lsp_server_dispatch.brp` with
  `LspWorkspace`; delete the duplicate document store and revision fields once
  migrated.
- Add `test_compiler_lsp_server_actor.brp`.
- Add `test_compiler_lsp_cancel_request.brp`.

**State model:**

- `LspNativeServerState` is a union whose variants contain the existing opaque
  `LspLifecycleState`: protocol-only, source-loading, ready, and exited. This is
  composition state, not a second lifecycle machine. Only the ready variant
  owns a complete `LspWorkspace`, the next cancellation token, optional active
  analysis metadata, and optional newest replacement plan.
- `LspActiveAnalysis` carries the exact token, scheduled revision, and plan sent
  to the worker.
- `LspPendingAnalysis` carries only the newest unsent plan. Replacing it is an
  explicit state transition, not a channel-capacity side effect.
- `LspServerEvent` distinguishes decoded client envelopes, source-load results,
  analysis completions, transport EOF/failure, and writer failure.
- `LspServerEffect` distinguishes sending one response/notification body,
  starting one analysis, refreshing one disk source, stopping the worker, and
  exiting with a typed status.

**Implementation order:**

- [x] Write a failing scoped-planning test with 100 catalog sources, one open
      document, one imported dependency, and 98 unrelated files. Require one
      publication target and exactly the open root plus reachable dependency in
      the discovered compiler graph.
- [x] Add ordered, unique root identities to `LspAnalysisPlan`. Derive them from
      current open-document layers through compiler identities, not from file
      names or the first sorted target.
- [x] Pass plan roots into `compiler_frontend_graph_discover` through a rooted
      LSP graph entry point; production analysis no longer supplies an empty
      root list or treats every catalog candidate as a root.
- [x] Limit `LspAnalysisTarget` values to open documents that need current
      diagnostics or later queries. Retain reachable dependency modules in the
      graph/typecheck result and dependency store without publishing diagnostics
      for their closed URIs.
- [x] Replace `plan_targets_cover_sources` with validation over required open
      targets and plan roots. Do not weaken source-snapshot equality: all
      candidate text used for resolution must still match the scheduled revision.
- [x] Cover two disconnected open roots in one graph wave, close of one root,
      an unopened dependency edit invalidating its open importer, and a newly
      opened former dependency becoming its own target.
- [x] Write a failing pure actor test for open revision 1, change revision 2
      while revision 1 analyzes, stale revision-1 completion, and one revision-2
      replacement start.
- [x] Introduce `LspNativeServerState` and constructors that make active-plus-
      pending analysis state explicit.
- [x] Change lifecycle dispatch for a valid first `initialize` from immediate
      acceptance/response into a typed initialization-request action. Keep
      `lsp_lifecycle_accept_initialize` as the sole commit operation and invoke
      it only after source loading succeeds.
- [x] Model initialize source loading as an explicit actor effect/result pair.
      Preserve the request ID across the effect and make success construct the
      only ready workspace state; failure must not expose a partial workspace.
- [x] On successful loading, call `lsp_lifecycle_accept_initialize`, construct
      ready state containing `LspAwaitingInitialized`, and send the initialize
      response. Only the later `initialized` notification transitions the
      contained lifecycle to `LspRunning`. On fatal loading failure, send exactly
      one error response with the retained initialize ID and return to the
      protocol-only pre-initialize state so a client may retry.
- [x] Define source-loading admission explicitly: a duplicate `initialize`
      request receives invalid-lifecycle, other requests receive
      server-not-initialized, notifications are ignored, and `exit` returns the
      pre-shutdown failure status. The reader may continue queueing frames while
      the effect runs.
- [x] Route lifecycle-admitted `didOpen`, `didChange`, `didSave`, and `didClose`
      through `lsp_apply_workspace_event`. Use one typed envelope router over the
      existing method codecs; do not reparse protocol fields in the actor.
- [ ] Remove direct document-store mutation from the compatibility dispatcher
      once its remaining diagnostic-publication tests use native actor state.
- [x] Make accepted `didOpen` produce a catalog-resolution effect and allow only
      its resolved result to construct `LspResolvedDocumentOpened`.
- [x] Interpret the `didOpen` effect with the R7 catalog before dequeuing the
      next client event. Because `didOpen` is a notification, an unsupported
      non-`file:` URI or out-of-root file is logged once and ignored together
      with later sync notifications for that URI; it does not produce a
      JSON-RPC response. The reducer never recreates a module identity from URI
      text.
- [ ] Extend `LspInitializeResult` to advertise save with
      `includeText: false` only after the R7 refresh effect is wired through the
      actor.
- [ ] Extend `LspInitializeResult` with a typed workspace-folder capability:
      initial folders supported, change notifications absent. Do not advertise
      `workspace/didChangeWorkspaceFolders` until the source catalog has an
      atomic root-change event.
- [x] Populate `serverInfo.version` from `compiler_build_info`; the public
      compiler version and LSP version must come from one generated build fact.
- [x] Do not analyze the whole catalog merely because initialization completed.
      The first `didOpen` transition selects the open target and its dependency
      graph; unopened files remain available as dependencies.
- [x] After every `LspAnalysisPlanRequired` transition, call
      `lsp_plan_analysis`. Start it immediately only when no analysis is active;
      otherwise replace the pending plan.
- [x] Assign monotonic cancellation tokens with a named constructor. Request
      IDs and workspace revisions are not cancellation tokens.
- [x] Run `lsp_run_compiler_analysis` on one dedicated serial worker. The actor
      must continue accepting frame events while that function runs.
- [x] Feed completion back as an actor event. Match its token to the active
      analysis before calling `lsp_apply_analysis_completion`.
- [x] Drop unknown-token and stale-revision completions without publishing,
      replacing caches, or clearing a newer pending plan.
- [x] After any active completion, start exactly the current pending plan, if
      present, then clear the pending slot.
- [x] Treat `$/cancelRequest` as a harmless no-op in the baseline because no
      advertised query waits on analysis. Keep the codec/routing point so R12
      can attach query waiters later.
- [ ] Add `lsp_cancel_request.brp` and a focused decoder/dispatch test now. It
      must retain integer/string IDs in valid cancellation params, reject
      malformed params as a notification without a response, and leave actor
      state unchanged at baseline.
- [x] On `didClose`, emit the reducer's guarded diagnostic clear immediately and
      schedule analysis only when the resulting source-layer change requires it.
- [x] On shutdown, respond immediately, reject new operational work, discard
      later diagnostic completions, and stop scheduling replacement plans.
- [x] On `exit`, return status 0 only after shutdown and status 1 otherwise, as
      required by the existing lifecycle model.
- [x] Ensure every effect is interpreted outside the pure actor transition.
      Filesystem reads, compiler calls, channel sends, and process exit do not
      occur inside the reducer.

**Required tests:**

- open, change, save, close, duplicate open, change-before-open, and stale
  document version through the canonical workspace;
- edit during analysis, three rapid edits retaining only the newest replacement,
  stale completion, wrong token, completion after close, and completion after
  shutdown;
- clean completion followed by error, error followed by clean, and close/reopen
  before completion;
- exactly one active compiler call under an instrumented worker;
- actor leak check over hundreds of immutable revisions; and
- scheduler tests with deliberately reordered event/completion delivery.

**Change-set boundaries:**

1. **R8A scoped planning:** explicit open roots, reachable graph discovery, open
   publication targets, and multi-root planner/compiler-service tests.
2. **R8B pure composition:** initialization action, server-state union, event
   and effect unions, canonical workspace routing, and pure actor tests.
3. **R8C worker scheduling:** one worker channel, active/newest-pending policy,
   completion admission, shutdown, leak checks, and reordered-delivery tests.

R8B must not start real compiler work. R8C must not contain stdio reads or
writes; those effects belong to R10.

**R8B composition foundation:** `lsp_server_event.brp` owns decoded client,
typed source-load, workspace, and analysis-completion events. The pure actor now
represents protocol-only, source-loading, ready, and exited states explicitly.
It retains the initialize request while an external loader constructs the whole
workspace, commits lifecycle state and responds only on success, permits retry
after fatal loading failure, correlates asynchronous results with opaque attempt
tokens, and applies source-loading admission without exposing a partial
workspace. Ready-state scheduling represents idle, active, and
active-with-newest-replacement as a closed union with opaque scalar cancellation
tokens. Shutdown retires scheduled work before late completions can publish or
restart analysis. Lifecycle-admitted document notifications now share one typed
codec router: change and close enter the workspace reducer directly, while open
resolution and save refresh remain explicit serial filesystem effects. Ready
state admits at most one such effect, assigns it an opaque monotonic token, and
accepts only a completion whose token and URI match that pending operation. A
client envelope dequeued before the pending effect is retired receives the
typed `LspServerDocumentEffectPending` actor error; the eventual interpreter
must therefore complete the effect before dequeuing another client envelope.
This prevents an edit or close from overtaking open resolution and prevents a
delayed save refresh from replacing newer disk state. Rejected open sessions
are remembered until close so later synchronization cannot create partial
state. There is no unrestricted workspace-change actor event: tests and
production document traffic use the same codec and admission path. Remaining
R8B work is compatibility-state retirement and capability completion; the
effect interpreter and worker loop remain deferred.

**Focused gates:**

```bash
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_server_actor.brp
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_cancel_request.brp
./blorp test --leak-check --suite compiler/blorp/tests/test_compiler_lsp_server_actor.brp
./blorp test --sanitize=undefined --suite compiler/blorp/tests/test_compiler_lsp_server_actor.brp
scripts/test compiler-blorp
```

**Exit criteria:** an in-memory actor integration test proves frame events remain
processable while a controlled worker is blocked, only the newest revision is
committed, and one serialized path owns all publications and state changes.

## R9: Complete Baseline Diagnostics

**Purpose:** turn compiler outcomes into one current, useful diagnostic
publication per affected open document. A native server that only reports parser
errors or silently drops graph failures is not viable.

The production cutover currently guarantees parser and typecheck diagnostics for
open documents, including clean-result clearing and stale-result suppression. The
unchecked items below are post-cutover diagnostic-completeness work. Until they
are complete, do not describe missing-import, closed-dependency, package, or
multi-root diagnostic behavior as a finished contract.

**Files:**

- Refine `lsp_compiler_service.brp` outcome construction.
- Refine `lsp_diagnostic.brp`, `lsp_diagnostic_model.brp`, and
  `lsp_diagnostic_codec.brp`.
- Add structured source locations in the owning compiler phase when import or
  declaration diagnostics lack them.
- Extend `test_compiler_lsp_diagnostics.brp` and
  `test_compiler_lsp_compiler_service.brp`.

**Publication contract:**

- One URI/revision produces one `publishDiagnostics` notification containing
  merged source-loading, parse, import, declaration, and typecheck diagnostics.
- A clean current result publishes an empty list, clearing prior errors.
- Only open documents receive publications. Closed documents receive one
  guarded clear and no later stale publication.
- `version` is present only when the client advertised diagnostic version
  support.
- Every diagnostic range is mapped against the exact source snapshot that
  produced its compiler span.
- A failure inside a closed dependency is not published to that closed URI.
  Instead, each affected open root receives one importer-owned summary at the
  exact import edge through which the failing dependency is reached. Attach the
  dependency's original location as `relatedInformation` when available. If the
  dependency is also open, it additionally receives its own detailed
  publication.
- Unlocated compiler-wide failures are logged to stderr and remain unlocated;
  they are never fabricated at line zero.

**Implementation order:**

- [x] Write a failing multi-module test where an open importer has a missing
      import and require a source-located diagnostic at the import path.
      `ParsedImportDecl.module_path_span` now preserves that parser-owned fact,
      and bound-module preparation retains structured typecheck diagnostics
      instead of erasing their spans through a `List[String]` boundary. The
      native process regression also proves the exact message, code, severity,
      URI, and UTF-16 range.
- [ ] Carry recoverable R7 loading issues with real source ownership into the
      same publication path. Log unlocated config/IO issues to stderr once per
      catalog revision; never synthesize a zero range in a `.brp` file.
      The current `LspSourceLoadIssue` variants contain filesystem paths,
      configuration identities, and IO details, but no compiler-owned `.brp`
      span. They therefore remain unlocated reports. Completing this item
      requires a producer to carry a real source span; path-to-URI conversion
      alone is not sufficient publication ownership.
- [ ] Ensure syntax parsing occurs for every planned target before graph
      typechecking can fail the wave. Preserve parse artifacts and diagnostics
      for independently parseable targets.
- [ ] Replace generic frontend-graph wave failure for ordinary unresolved
      imports with per-target structured diagnostics. Reserve worker failure for
      infrastructure or violated compiler invariants.
- [ ] Preserve source spans on compiler frontend import edges and retain enough
      root-to-failure path information to build the closed-dependency summary.
      The LSP may adapt compiler facts into summary text, but may not find the
      import span by searching source text.
- [ ] Preserve diagnostics when semantic-index extraction fails. Semantic index
      availability cannot suppress baseline parse/type diagnostics.
- [x] Merge phase publications by URI and snapshot identity before encoding.
      Define deterministic phase/order sorting and exact duplicate elimination.
      `lsp_merge_diagnostic_fragments` owns the canonical source-loading,
      parse, import, declaration, and typecheck precedence, preserves producer
      order within each phase, removes only exact duplicates, and always emits
      one publication even when its diagnostic list is empty. The compiler
      service routes parse and typecheck fragments through this assembler;
      later located loading/import summaries use the same typed boundary.
- [ ] Convert declaration and module diagnostics using their compiler-owned
      spans. Add spans in the parser/module/typecheck phase where necessary,
      never in LSP code through source-text search.
- [ ] Apply `lsp_apply_analysis_completion` before selecting publications so
      cache/index and diagnostics share one accepted revision boundary.
- [ ] Filter committed publications through the actor's current open-document,
      workspace-revision, configuration-epoch, content-fingerprint, and document-
      version checks.
- [ ] Publish an empty current list after errors are fixed even when the compiler
      returns no diagnostic objects.
- [ ] Keep warning severity, diagnostic code, help text, and UTF-16 ranges stable
      through JSON encoding.

**Required tests:**

- parser error, warning, unknown name, type mismatch, duplicate declaration,
  missing local import, broken imported module, import cycle, and package import
  failure;
- closed broken dependency producing an importer summary with related
  information, then opening that dependency producing its detailed diagnostics;
- dependency overlay fix invalidating importer, error-to-clean, clean-to-error,
  parse-error-to-type-error, and two diagnostics from different phases;
- non-ASCII source before and inside a diagnostic span;
- stale revision, stale configuration epoch, stale document version, close,
  close/reopen, and non-versioned client;
- semantic-index extraction failure retaining diagnostics; and
- process-independent normal, leak-check, ASan, and UBSan tests.

**Change-set boundaries:**

1. **R9A compiler diagnostics:** add missing compiler-owned spans and convert
   ordinary graph/import failures into per-target outcomes. This change must be
   useful to non-LSP compiler clients where the production diagnostic type is
   shared.
2. **R9B publication assembly:** retain partial parse/typecheck results, merge
   diagnostics deterministically, and encode one URI/revision publication.
3. **R9C actor admission:** commit analysis first, apply all currentness guards,
   then emit publications or clears as actor effects.

**Focused gates:**

```bash
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_diagnostics.brp
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_compiler_service.brp
./blorp test --leak-check --suite compiler/blorp/tests/test_compiler_lsp_diagnostics.brp
scripts/test compiler-blorp-sanitize
scripts/test compiler-blorp
```

**Exit criteria:** a multi-file workspace test can introduce and fix parse,
import, and type errors through overlays, and the observer receives exactly the
current merged publication or clear for each revision.

## R10: Raw Stdio, Framing, And Native Process

**Purpose:** run the completed baseline as a real byte-accurate LSP process
without invoking the OCaml host.

**Files:**

- Add compiler-private raw stdin/stdout builtins and runtime declarations in the
  normal builtin metadata, runtime declaration, and `runtime.c` ownership paths.
- Add `lsp_frame_codec.brp` for the pure incremental frame decoder/encoder.
- Add `lsp_stdio_transport.brp` for raw IO only.
- Add `lsp_native_server.brp` for reader, actor, worker, and writer composition.
- Add a small native LSP entry source and `make blorp-lsp-native` target.
- Add `scripts/test lsp-native` and process fixtures under
  `tests/lsp/native_baseline/`.

**Raw IO contract:**

- Expose compiler-private operations equivalent to
  `compiler_stdin_read(max_bytes) -> CompilerStdinReadOutcome` and
  `compiler_stdout_write_all(bytes) -> Result[Void, CompilerStdioError]`.
  `CompilerStdinReadOutcome` has distinct data, EOF, and failure variants; EOF
  is not an empty successful chunk.
- A write is write-all: it either writes every byte or returns a typed failure.
- Interrupted syscalls retry. Short reads and short writes are normal internal
  progress, not protocol failure.
- Suppress process-terminating `SIGPIPE` for this transport so a closed client
  stdout pipe becomes a typed `EPIPE` write failure on Linux and macOS.
- Put stdin/stdout into the runtime's existing nonblocking/reactor path. Waiting
  for pipe readiness must yield the current fiber instead of pinning a scheduler
  worker in `read(2)` or `write(2)`.
- Extend the existing `blorp_IoWaitOwner` model with one process-owned stdio
  owner registered once for descriptors 0 and 1, with separate read/write waiter
  slots and a stable generation. Do not pass `BLORP_IO_WAIT_OWNER_NONE` or build
  a private polling loop; those paths cannot park and wake a fiber correctly.
- Never close process-owned stdin or stdout from a compiler-private wrapper.
- These primitives remain compiler-private until separately designed as a std
  API.

**Process-exit contract:** normal runtime teardown joins active worker tasks, so
returning from `main` is not sufficient while a typecheck is running. Add one
compiler-private immediate process-exit operation for the native server. It may
run only after the actor produces a terminal process outcome. On an admitted
`exit` or clean EOF, stop accepting outbound messages and discard notifications
that the writer has not started. Give an in-flight frame
`LSP_EXIT_DRAIN_TIMEOUT_MILLISECONDS = 250` to finish, then terminate even if the
client is not reading; a failed writer cannot be drained. The short named grace
period preserves an already-started small response without letting protocol exit
hang behind client backpressure. The operation terminates with the actor's status
without waiting for analysis or running ordinary ARC teardown; the operating
system reclaims process resources. It is not a public std API and is never used
for shutdown alone or an ordinary compiler-analysis failure.

**EOF/error policy:** clean stdin EOF at a frame boundary is a successful
transport close for compatibility with `blorp lsp </dev/null`; emit no protocol
response, drain the writer, and exit 0. EOF with a partial header/body, malformed
framing, raw read failure, or writer failure logs one stderr diagnostic and exits
nonzero. An LSP `exit` notification still uses lifecycle status 0 only after
shutdown and status 1 otherwise.

**Frame codec contract:**

- Parse ASCII header names case-insensitively and require exactly one valid
  `Content-Length` value. Reject every duplicate, including equal duplicates,
  so there is one unambiguous rule. Validate an optional `Content-Type` as
  `application/vscode-jsonrpc` with UTF-8, ignore other well-formed unknown
  headers, and reject malformed header lines or non-ASCII header bytes.
- Recognize `\r\n\r\n` as the header terminator. Do not use line-oriented stdin
  APIs or character counts for body length.
- Retain partial headers and bodies across reads and emit multiple complete
  frames from one input chunk.
- Count body bytes, then decode the complete body as UTF-8 JSON text.
- Reject negative, non-decimal, overflowing, or over-limit lengths with a typed
  transport error.
- Define named configurable defaults for maximum header and body bytes. Document
  the resource-safety reason beside the defaults; do not scatter numeric limits.
- Use `LSP_MAX_HEADER_BYTES = 64 * 1024` and
  `LSP_MAX_MESSAGE_BODY_BYTES = 16 * 1024 * 1024` for the first checkpoint. The
  header allowance is far above normal LSP metadata while bounding malformed
  input; the body allowance is more than an order of magnitude above the
  repository's largest ordinary source module while keeping one request bounded.
  Tests cover exactly-at-limit and one-byte-over-limit behavior.
- Encode responses as ASCII `Content-Length: N\r\n\r\n` plus exact UTF-8 body
  bytes.
- Consume each input chunk with a cursor and never retain or slice its unread
  suffix. Retain incomplete header/body bytes in a geometrically coalesced
  immutable chunk stack only after validating the applicable bound. This keeps
  only logarithmically many chunks, avoids hidden full-buffer COW under Blorp
  value semantics, and avoids quadratic concatenation. Flatten once when the
  header or body completes; do not decode partial UTF-8 bodies.

**Process topology:**

```text
stdin reader -> frame bodies -> serialized actor -> outbound JSON bodies -> stdout writer
                                      |
                                      +-> one serial compiler worker -> completion events
                                      +-> source load/save effects -> source events
```

Only the writer task writes stdout. Logs and internal failures go to stderr.
The reader never runs compiler analysis. The worker never mutates workspace
state or publishes directly.

Use one-slot reader-to-actor and actor-to-writer channels named
`LSP_INBOUND_FRAME_BUFFER_CAPACITY` and `LSP_OUTBOUND_BODY_BUFFER_CAPACITY`.
The capacity is deliberately one: it decouples the adjacent fibers while making
backpressure and maximum retained message memory obvious. Backpressure may pause
frame ingestion; dropping a request, response, diagnostic, or actor event is not
allowed. The worker path contains at most one active and one pending analysis by
R8, so it does not need a general work queue.

**Implementation order:**

- [x] Write failing runtime tests for raw read EOF, short read, non-ASCII bytes,
      embedded NUL, write-all, broken pipe, and ownership release.
- [x] Implement the compiler-private raw IO builtins and audit generated C plus
      resource/consume metadata.
- [x] Write pure failing frame tests before implementing the incremental decoder.
- [x] Implement framing independently of JSON-RPC and actor modules. Convert a
      complete body from bytes to UTF-8 text exactly once, and convert an
      outbound JSON string to UTF-8 bytes exactly once before calculating
      `Content-Length`.
- [x] Compose dedicated reader and writer loops with the R8 actor and worker.
- [x] Decode each body once with `decode_lsp_json_rpc_body`; pass the resulting
      envelope through lifecycle admission before operational dispatch.
- [x] Preserve the existing JSON-RPC distinction: malformed JSON receives a
      parse-error response with ID `null`; valid JSON whose envelope or method
      parameters fail validation retains a valid request ID. Close only on
      unrecoverable framing/transport errors, not a malformed JSON body.
- [x] Keep initialize capabilities limited to the Native Baseline Contract.
- [x] Add the writer drain acknowledgement and compiler-private immediate-exit
      operation. Prove shutdown responds normally, while a later `exit`
      terminates even when an instrumented analysis worker remains blocked.
- [x] Add a process test whose client stops reading with a large response in
      flight, then closes stdin or sends `exit`. Require termination within the
      named drain grace plus test scheduling tolerance.
- [x] Supersede the temporary `blorp-lsp-native` checkpoint with an atomic direct
      route switch after the same process contract was exercised against a
      separately linked native binary.
- [x] Build every compiler-owned Blorp entry through the existing pinned
      resolver contract: use `BLORP_BOOTSTRAP_COMPILER_BIN` when explicitly set,
      otherwise `scripts/blorp-compiler-bootstrap --print-path`. Reuse the main
      target's manifest hashing, generated runtime source, compiler macro, include
      paths, and link flags. Do not compile this executable with the just-built
      `./blorp` or add a second bootstrap selector.
- [x] Add a process fixture that sends initialize, initialized, didOpen,
      didChange, shutdown, and exit and validates framed responses and
      diagnostics. Fragmented transport input remains covered at the raw stdio
      and pure framing boundaries.
- [ ] Add fixtures for two frames in one write, non-ASCII body byte length,
      malformed header, incomplete EOF, unknown request, unknown notification,
      unexpected EOF, stdout purity, and exit status.

**Change-set boundaries:**

1. **R10A raw IO:** runtime/builtin declarations, generated-C audit, EOF/error
   semantics, reactor-safe waiting, ownership tests, and sanitizer coverage.
2. **R10B pure framing:** incremental decoder/encoder and exhaustive chunking,
   limit, UTF-8, and malformed-header tests. This slice imports no actor or
   compiler module.
3. **R10C native process:** bounded channels, reader/actor/worker/writer
   composition, pinned-bootstrap build target, and native process fixtures.

**R10A raw IO checkpoint:** `lsp_stdio_transport.brp` exposes distinct data,
EOF, and typed-failure reads plus a write-all operation without making these
process-lifetime primitives public std APIs. The runtime preserves descriptor
flags while putting stdin and stdout into nonblocking mode, retries interrupted
and partial syscalls, ignores `SIGPIPE` once for the native compiler process,
and reports a closed stdout pipe as a typed write failure. A process-owned
`blorp_IoWaitOwner` with independent read and write slots parks fibers on the
shared reactor without closing descriptors 0 or 1. Operation-result metadata
transfers the owned read `Bytes` payload and borrows write input across a parked
operation. Focused Blorp tests, generated-C expectations, process tests with
delayed fragmented input and backpressured output, leak instrumentation, and
ASan/UBSan cover this boundary. The process harness is part of `scripts/test
lsp`; R10C will add the dedicated native-process gate and composition fixtures.

**R10B framing checkpoint:** `lsp_frame_codec.brp` is a pure incremental byte
state machine with opaque positive limits. It consumes each input chunk through
a cursor and stores incomplete sections as geometrically coalesced immutable byte
chunks. The representation keeps only logarithmically many chunks, preserves
decoder value semantics, avoids full-buffer COW on each fragment, and flattens a
completed section once. It never copies an unread input suffix. A terminal
framing error carries any bodies that were completed earlier in the same read,
allowing the transport to dispatch those messages before closing; the obsolete
single-frame transport trait was removed so R10C must model that ordering
explicitly. Header parsing enforces one case-insensitive decimal
`Content-Length`, an optional LSP UTF-8 `Content-Type`, ASCII HTTP field syntax,
bounded header/body sizes, and exact CRLF framing. Completed bodies receive a
non-allocating UTF-8 validity scan before their single conversion to `String`;
the encoder validates outbound UTF-8 and computes length from the encoded bytes.
EOF distinguishes a clean frame boundary from incomplete header and body states.
Native process composition is implemented in `lsp_native_server.brp`.

**R10C native-process checkpoint:** the public process uses a detached raw reader,
one serialized actor, one serial compiler worker, and one dedicated stdout
writer. One-slot channels bound retained transport and work-queue data. The actor
never performs stdout IO; an outbound enqueue has a named timeout so a stopped
client cannot indefinitely block lifecycle admission. Terminal outcomes seal the
writer queue, allow an in-flight frame a 250 ms named drain period, and then use
the compiler-private process exit shim so blocked detached IO or analysis fibers
cannot hold the process open. The same shim raises an undersized configured fiber
stack to a 2 MiB compiler-worker minimum before scheduler startup; full prelude
typechecking exceeds 512 KiB on macOS and passes at 1 MiB, so the production
minimum retains one doubling of headroom. The LSP entry point applies it
immediately before the lazily initialized scheduler creates its first channel
or fiber, so non-LSP compiler commands and generated programs are unaffected.
Native harness, repository-root, tuple-implementation, and package-import
process regressions cover that contract.

**Focused gates:**

```bash
make
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test compiler-blorp-sanitize
scripts/test leak
scripts/test lsp
```

**Exit criteria:** `scripts/test lsp` launches `./blorp lsp`, passes complete
framed sessions, proves current diagnostics, and proves terminal lifecycle
handling remains responsive under stdout backpressure. No fixture or production
route invokes the OCaml LSP host.

## R11: Production Cutover And OCaml LSP Deletion

**Purpose:** make the native baseline the only LSP implementation. Cutover and
deletion are one change; do not add `BLORP_LEGACY_LSP`, method fallbacks, or a
second production executable.

**Cutover validation:**

- [x] Inspect the native initialize response and verify every advertised field
      has a process fixture. Verify every deferred provider field is absent, not
      present with a false or placeholder implementation unless LSP requires it.
- [ ] Run the native server in VS Code and IntelliJ against a multi-file
      workspace. Verify startup, unsaved diagnostics, save, close, rapid edits,
      clean shutdown, and no stdout contamination.
- [x] Measure initialization and edit-to-diagnostic latency on the Blorp repo.
      Record numbers in the change description; optimize only measured blockers.
- [x] Confirm package and standard-library imports produce no false diagnostics
      in a valid project.

One local process sample on 2026-08-14 measured repository initialization at
408.1 ms, opening a small document through clean diagnostics at 19.4 ms, its
subsequent invalid edit at 0.3 ms, and a `std/bytes` plus `pkg/crypto` document at
100.3 ms. These are cutover smoke measurements, not a stable benchmark contract.

**Test migration:**

- [x] Split `tests/lsp/run_lsp_fixtures.py` into baseline process fixtures and
      post-cutover capability fixtures, or add an explicit fixture capability
      manifest. Tests for unsupported semantic methods remain preserved but do
      not run against the baseline as if those methods were advertised.
- [x] Refactor the process client to queue unmatched responses and notifications
      instead of discarding them while waiting for one request ID or diagnostic.
      Concurrent diagnostics and later shared analysis queries otherwise make
      the fixture runner itself nondeterministic.
- [x] Make every initialize fixture send the required `processId` field, using
      `null` when the test does not model a client process. The current public
      fixture omits it and would be rejected by the native decoder.
- [x] Make `scripts/test lsp` launch `./blorp lsp` and run the native baseline
      process fixtures. Remove the temporary `lsp-native` gate after route
      replacement.
- [x] Update public-command process tests to assert that `blorp lsp` starts,
      frames initialize, and exits correctly, rather than merely accepting EOF.
- [x] Add a test that fails if the `lsp` command executes or references the
      OCaml-host LSP plan.

**Route and deletion order:**

- [x] Import the native server entry point into `stage_12_cli/cli_main.brp` and
      execute it directly for `CliRunLsp`.
- [x] Remove `CliOcamlHostLsp` from `cli_plan.brp`, its JSON encoding in
      `cli_artifact_json.brp`, and the OCaml bridge decode/dispatch branch.
- [x] At LSP cutover time, the OCaml host remained temporarily for package and
      bootstrap behavior. Those consumers and the host have since been removed.
- [x] Delete `compiler/lib/lsp/` and its Dune module references after repository
      search proves no remaining production consumer. Do not edit or delete the
      frozen, non-executable `compiler/test/test_lsp_*.ml` archive; record it as
      historical in the existing OCaml coverage ledger if needed.
- [x] Remove stale LSP JSON bridge helpers and dependencies that become
      unreachable. Use compiler/build inventory tests to prevent accidental
      retention.
- [x] Keep `./blorp lsp` as the sole supported entry point; no temporary native
      executable target remains.
- [x] Update architecture, CLI, editor, packaging, and release documentation.
      Release packaging now contains only the public Blorp executable.

**Change-set boundaries:**

1. **R11A cutover preparation:** capability manifest, baseline fixture split,
   public-command test support, editor smoke checks, and recorded latency. The
   production route remains OCaml in this change.
2. **R11B atomic cutover:** route `CliRunLsp` to native code, remove the LSP host
   plan/bridge, delete OCaml LSP sources and Dune entries, remove the temporary
   native executable, update docs, and pass all required gates. Do not leave an
   intermediate commit where both production routes are selectable.

Before R11B, save the exact expected initialize response in a process fixture.
During R11B, update only the executable path used by that fixture; its expected
capability object must not change.

**Required gates:**

```bash
make
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
scripts/test cli
scripts/test lsp
scripts/premerge-gate
```

Also run repository searches for `CliOcamlHostLsp`, `BlorpCliLsp`,
`Lsp_server.run`, and `compiler/lib/lsp`; every result must be either removed or
an explicitly historical document or frozen OCaml test-archive reference.

**Exit criteria:** `./blorp lsp` starts no OCaml process, advertises only the
baseline contract, passes native process fixtures, and the OCaml LSP source and
dispatch are deleted. The absence of semantic providers is intentional and
documented, not treated as a hidden compatibility gap.

## Post-Cutover Rule

R12-R18 happen after R11. Each capability is independently releasable. Add its
initialize capability only in the same change that wires its real process route
and process fixture. Unit tests for a model, codec, or handler are not sufficient
to advertise it.

## R12: Shared Query Protocol And Snapshot Dispatch

**Purpose:** add request admission, snapshot selection, cancellation, and
response ownership once. Method handlers remain pure and method-specific; this
slice must not introduce a generic untyped JSON handler registry.

**Prerequisites:** R11. No capability is advertised by R12 itself.

**Files:**

- Add `lsp_query_model.brp` for query stamps, artifact requirements, pending
  requests, and terminal outcomes.
- Add `lsp_query_codec.brp` only for shared text-document, position, range, and
  reference-context parameter shapes.
- Extend `lsp_server_event.brp` and `lsp_server_actor.brp` with pending-query
  state and cancellation events.
- Add `test_compiler_lsp_query_dispatch.brp`.

**Query ownership contract:**

- `LspPendingQuery` owns one request ID, method identity, URI, admitted workspace
  revision, optional document version, required artifact class, and cancellation
  token. Request IDs are never repurposed as cancellation tokens.
- Method identity is a closed `LspPendingQueryKind` union carrying each method's
  validated parameters. Do not store encoded JSON, string method tags, or
  captured response callbacks in pending state.
- Syntax queries may run against an exact current lexed/parsed snapshot.
  If that snapshot does not exist yet, they wait on the current/newest analysis
  wave exactly like a typed waiter; completion may satisfy them from a retained
  lexed/parsed outcome even when typechecking failed. Semantic
  queries require a typed artifact whose URI, configuration epoch, source
  fingerprint, and document version match the admitted request.
- A query never silently moves to newer text. A superseding edit completes it
  with the named content-modified outcome; explicit client cancellation and
  shutdown use the named request-cancelled outcome.
- One analysis wave may satisfy diagnostics and multiple pending queries. The
  analysis plan does not own a request ID.
- Every admitted request receives exactly one success or error response. Unknown
  notifications and `$/cancelRequest` itself receive no response.

**Implementation order:**

- [ ] Write a failing actor test for two semantic queries sharing one analysis,
      cancellation of one waiter, successful completion of the other, and one
      diagnostic publication from the same wave.
- [ ] Define typed document-only, position, range, and reference-context decoders
      that preserve integer and string request IDs on parameter failure.
- [ ] Add `LspQueryArtifactRequirement` variants for lexed, parsed, and typed
      snapshots rather than boolean `requires_analysis` flags.
- [ ] Add an opaque pending-query store indexed by request ID. Reject a duplicate
      outstanding ID deterministically without replacing the original waiter.
- [ ] Map a UTF-16 position only after selecting the exact source snapshot. Keep
      protocol position errors distinct from missing-document and stale-artifact
      outcomes.
- [ ] Answer immediately when a compatible artifact exists. Otherwise attach a
      typed waiter of the required lexed, parsed, or semantic class to the
      current or newest pending analysis plan.
- [ ] On an edit, close, configuration change, shutdown, worker failure, or
      client cancellation, remove affected waiters and emit their terminal
      responses in the same actor transition.
- [ ] Use named protocol constructors for method-not-found, invalid-params,
      request-cancelled, content-modified, and internal failures; do not repeat
      JSON-RPC/LSP numeric codes in method modules.
- [ ] Make null, empty-list, and error outcomes explicit in each method result
      union. The shared layer must not guess which one a method requires.
- [ ] Add actor invariants proving no waiter survives a terminal response and no
      completion can respond twice.

**Required tests:** integer/string IDs, malformed params, unopened URI, invalid
UTF-16 position, immediate lexed/parsed result, queued parsed result surviving a
typecheck failure, immediate typed result, queued typed result, two waiters
sharing analysis, explicit cancellation, superseding edit, close, configuration
change, worker failure, shutdown, duplicate ID, stale completion, and response
exactly-once counting.

**Focused gates:**

```bash
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_query_dispatch.brp
./blorp test --leak-check --suite compiler/blorp/tests/test_compiler_lsp_query_dispatch.brp
scripts/test compiler-blorp-sanitize
scripts/test lsp
```

**Exit criteria:** a dummy parsed query and dummy typed query pass through the
real native process, including cancellation and superseding edits, while the
initialize response still advertises no query capability.

## R13: Document Symbols

Implement this first because it needs only a parsed artifact and remains useful
while the source has type errors.

**Files:** add `lsp_document_symbol_model.brp`,
`lsp_document_symbol_codec.brp`, `lsp_document_symbol.brp`, and
`test_compiler_lsp_document_symbols.brp`.

**Result contract:** preserve declaration source order. Hierarchical-symbol
support is negotiated during `initialize` and retained in immutable ready server
state. Use hierarchical `DocumentSymbol[]` when supported and flat
`SymbolInformation[]` otherwise. An open current document with no declarations
returns `[]`; an unavailable document returns the method's typed null/error
policy, not stale symbols.

**Implementation order:**

- [ ] Extend `LspInitializeParameters` and initialized actor capability state
      with `textDocument.documentSymbol.hierarchicalDocumentSymbolSupport`.
      Decode `DocumentSymbolParams` separately; method params do not carry client
      capabilities.
- [ ] Traverse production parsed declarations, never source lines or formatter
      indentation.
- [ ] Emit functions, globals, records/structs, unions/enums, aliases, opaque
      types, traits, implementations, and foreign functions.
- [ ] Nest fields, variants, and methods under their parsed owner. Define the
      flat fallback's `containerName` from the same ownership relation.
- [ ] Use full declaration spans for `range` and identifier spans for
      `selectionRange`; convert through the selected snapshot's UTF-16 index.
- [ ] Map compiler declaration categories through a closed `LspSymbolKind` enum.
      Do not store protocol kind numbers in compiler AST values.
- [ ] Preserve useful declarations from a partial parsed artifact and omit only
      declarations the production parser did not construct.
- [ ] Route the request through R12, add its process fixture, then advertise
      `documentSymbolProvider: true` in that same change.

**Required tests:** every declaration category, nested members, duplicate names
under different owners, source order, empty module, malformed trailing body,
non-ASCII before names, invalid URI/position-independent params, hierarchical
client, flat client, stale parse artifact, and process capability honesty.

**Focused gates:**

```bash
./blorp test --suite compiler/blorp/tests/test_compiler_lsp_document_symbols.brp
./blorp test --leak-check --suite compiler/blorp/tests/test_compiler_lsp_document_symbols.brp
scripts/test compiler-blorp
scripts/test lsp
```

**Exit criteria:** VS Code and IntelliJ outline views show the same complete
declaration tree for a representative compiler module, including while an
unrelated function body contains a syntax error.

## R14: Definition, Declaration, Type Definition, References, And Highlights

These methods share compiler identity and location indexes and should be built
as one navigation subsystem with separate typed destination policies.

**Files:** extend compiler definition/occurrence artifacts; add
`lsp_navigation_model.brp`, `lsp_navigation_codec.brp`,
`lsp_navigation.brp`, `lsp_references.brp`, and
`test_compiler_lsp_navigation.brp`.

**Identity contract:** every result originates from a compiler-issued
`LspSemanticSymbolId`. Text equality, name prefixes, AST shape, and nearby
declaration searches are forbidden fallbacks. A workspace-wide operation either
has complete coverage for the requested symbol or returns a typed coverage
failure; it must not silently label a partial result complete.

**Reference coverage contract:** background diagnostics analyze only open roots
and reachable dependencies, so their semantic indexes cannot prove workspace-
wide references for an exported symbol. Artifact-local symbols need only their
own module. For an exported symbol, R14C schedules an on-demand reference-
coverage wave whose roots are every catalog module that compiler visibility and
package-confinement rules permit to reference the symbol; all catalog sources
remain candidates. Cache that coverage by catalog/configuration
fingerprint and invalidate it on any source/configuration change. If any eligible
module cannot produce the required semantic category, return a typed coverage
failure rather than a partial location list.

**Implementation order:**

- [ ] Write failing compiler tests for parameter/local definition IDs, declaration
      spans, references, shadowing, and returned/captured lambdas.
- [ ] Extend typed artifacts and semantic occurrence extraction for parameters,
      locals, traits, and methods. Preserve identity through generic
      instantiation, desugaring, and imported aliases.
- [ ] Reuse the existing opaque index's exact UTF-16 selection-range lookup
      (`lsp_module_semantic_index_symbol_at`) for navigation. Extend its category
      coverage with the new parameter/local/trait/method occurrences; do not add
      a parallel byte-position index unless measurement proves the current map
      representation is a problem.
- [ ] Add workspace lookup by exported ID and artifact-local lookup by artifact
      ID plus definition ID. Return exact index coverage failures.
- [ ] Implement definition and declaration destination policies separately,
      even when Blorp currently maps both to the same source location.
- [ ] Define embedded-std navigation policy explicitly. A configured on-disk std
      may return a `file:` location. An embedded-only declaration is marked
      non-navigable and returns no location until an editor-readable virtual
      document or stable materialization mechanism is implemented; never return
      a fake checkout path.
- [ ] Implement type definition from the resolved semantic type. Document alias
      behavior by occurrence class. An explicit source type occurrence navigates
      through its compiler-owned type-reference identity, preserving a written
      alias. An inferred expression with no written alias navigates to the
      resolved concrete record, union, enum, struct, or opaque declaration.
- [ ] Encode `LocationLink[]` only when the client advertises link support;
      otherwise encode `Location[]`. Preserve origin, target declaration, and
      target selection ranges in the internal result either way.
- [ ] Implement references over the workspace identity index with exact
      `includeDeclaration` handling and deterministic URI/range ordering.
- [ ] Add the on-demand reference-coverage plan and cache. Prove local symbols do
      not trigger a workspace wave, exported symbols do, broken unrelated modules
      cause an explicit coverage failure, and a later edit invalidates prior
      coverage.
- [ ] Derive document highlights from references filtered to the selected URI.
      Emit read/write kinds only when compiler occurrence metadata proves them;
      otherwise use the neutral text kind.
- [ ] Wire and advertise definition, declaration, type definition, references,
      and document highlights one at a time. Each advertisement requires its own
      process fixture and may be reverted independently.
- [ ] Extend `tests/lsp/run_lsp_fixtures.py` with explicit `declaration` and
      `typeDefinition` method mappings and result assertions before claiming all
      five native routes are covered.

**Required tests:** local/global/function/type/field/constructor/trait/method
symbols; parameters and shadowed locals; selective and qualified imports;
same-spelling symbols from two modules; private artifact-local symbols; generic
functions and types; record updates and assignment writes; union patterns;
aliases and opaque types; declaration inclusion; UTF-16; malformed source;
stale/missing index; incomplete coverage; cancellation; all five process routes.

**Change-set boundaries:** R14A completes identities and index lookup without
advertising methods. R14B ships definition/declaration/type definition. R14C
ships references/highlights after complete workspace coverage is proven.

**Exit criteria:** navigation never crosses between same-spelling distinct
identities, and every advertised method passes cross-module native process tests.

## R15: Hover

**Files:** add `lsp_hover_model.brp`, `lsp_hover_codec.brp`, `lsp_hover.brp`, and
`test_compiler_lsp_hover.brp`. Add canonical display helpers beside compiler
types/signatures when no production renderer exists.

**Implementation order:**

- [ ] Resolve the smallest typed expression, pattern, declaration, parameter,
      local, field, constructor, or type span containing the requested position.
- [ ] Render types and callable signatures through compiler-owned canonical
      display helpers, including generic parameters, instantiated arguments,
      purity, parameter names, and return type.
- [ ] Start with `plaintext` markup. Add Markdown only after escaping and client
      negotiation have dedicated tests; do not embed source-controlled text in
      Markdown accidentally.
- [ ] Return JSON `null` for whitespace, comments, unknown positions, or an
      unavailable exact typed artifact. Never infer hover content from spelling.
- [ ] Preserve the exact source range that caused the hover and convert it
      against the matching snapshot.
- [ ] Add the actor route and process fixture, then advertise
      `hoverProvider: true`.

**Required tests:** each symbol category, inferred local, imported symbol,
generic callable before/after instantiation, pure/impure functions, nested
expression choosing the smallest span, whitespace/comment null, malformed
source null, non-ASCII, stale artifact, cancellation, and process response.

**Exit criteria:** hover signatures match compiler diagnostic/type rendering and
the handler returns no plausible-but-unproven result when exact typing is absent.

## R16: Completion

Completion is the largest post-cutover feature because source is commonly
incomplete. It must degrade explicitly from typed to parsed/lexed context.

**Files:** add compiler-owned cursor context/scope queries beside parsed and
typed artifacts; add `lsp_completion_model.brp`, `lsp_completion_codec.brp`,
`lsp_completion.brp`, and `test_compiler_lsp_completion.brp`. Migrate preserved
fixtures under `tests/lsp/fixtures/completion/` to the native process.

**Response policy:** completion is latency-sensitive and does not wait for a new
typecheck. Use an exact current typed artifact when present; otherwise answer
from the exact current partial parsed/lexed artifacts with visibly reduced
filtering. Return `isIncomplete: true` when better semantic filtering could
become available. Do not return results from a stale typed artifact.

**Implementation order:**

- [ ] Define compiler-owned cursor contexts for expression, type, import,
      UFCS/member, record literal, pattern, and declaration positions. Build
      context from production tokens/AST recovery, not a private prefix parser.
- [ ] Add scope queries for lexical locals, parameters, module declarations,
      imported exports, types, fields, trait methods, variants, and prelude
      symbols.
- [ ] Preserve incomplete-source context through parser recovery for a trailing
      identifier, trailing `.`, open call, unfinished import, and partial record
      literal. Improve the production parser's recovery when facts are missing.
- [ ] Apply scope and visibility in parsed mode. In typed mode additionally apply
      expected type, receiver type, generic substitution, and current function
      purity.
- [ ] Define named deterministic ranking tiers: exact local scope, parameters,
      module declarations, explicit imports, receiver members, prelude, and
      auto-import candidates if later enabled. Sort ties by stable display name
      and identity, not dictionary iteration.
- [ ] Deduplicate by compiler identity plus insertion text. Same labels with
      distinct identities remain representable when the client can disambiguate
      them through detail text.
- [ ] Support ordinary invocation and `.` trigger. Do not advertise snippets,
      commit characters, resolve provider, or additional text edits initially.
- [ ] Encode label, kind, detail, sort/filter text, and exact replacement range.
      Keep protocol item-kind numbers behind a typed enum.
- [ ] Run every preserved completion fixture against the native process, add
      malformed/stale cases, then advertise `completionProvider` with `.` as the
      only trigger character.

**Required tests:** local scope and shadowing; type context; selective/qualified
imports; list/string/record/trait UFCS; same-named fields; record literal fields;
constructors and patterns; purity filtering; generic receiver substitution;
partial syntax forms; whitespace; UTF-16 replacement range; deterministic order;
parsed fallback; exact typed enrichment; stale typed rejection; process latency.

**Change-set boundaries:** R16A compiler cursor/scope APIs, R16B parsed fallback,
R16C semantic filtering/ranking, and R16D process route plus advertisement.

**Exit criteria:** all preserved completion fixtures pass without OCaml code,
results stay useful during ordinary incomplete typing, and no stale semantic
candidate is presented as current.

## R17: Signature Help And Inlay Hints

These are separate capabilities but reuse callable/type rendering. Implement and
advertise them independently.

**Files:** add `lsp_signature_help_model.brp`,
`lsp_signature_help_codec.brp`, `lsp_signature_help.brp`,
`lsp_inlay_hint_model.brp`, `lsp_inlay_hint_codec.brp`,
`lsp_inlay_hint.brp`, and focused test files for each.

**Signature-help order:**

- [ ] Find the innermost production parsed call containing the cursor and derive
      the active argument structurally. Nested calls, strings containing commas,
      lambdas, and multiline calls must not confuse it.
- [ ] Resolve candidate callables through compiler identity and exact typed
      overload resolution when a current typed artifact exists. For an incomplete
      call that has only a current parsed artifact, reuse R16's compiler-owned
      scope query and return uninstantiated signatures for structurally visible
      candidates; do not perform private textual overload inference.
- [ ] Reuse canonical callable rendering from hover and return exact parameter
      label ranges rather than searching the rendered text afterward.
- [ ] Support `(` and `,` triggers plus explicit invocation; return `null` when
      no exact call/candidate exists.
- [ ] Add native process fixtures, then advertise `signatureHelpProvider` with
      the exact trigger set.

**Inlay-hint order:**

- [ ] Start only with inferred immutable and mutable local-binding type hints.
      Do not include parameter-name, chaining, or closing-brace hints.
- [ ] Emit a hint only when the typed binding has no explicit source annotation
      and its inferred type has a stable canonical rendering.
- [ ] Use the compiler-owned insertion span after the binding name; filter by
      the requested UTF-16 range before encoding.
- [ ] Define whether trivial literal types are omitted in one named policy and
      test that policy. Do not scatter type-name exclusions.
- [ ] Add native process fixtures, then advertise `inlayHintProvider`
      independently of signature help.

**Required tests:** nested/UFCS/generic/overloaded calls, malformed calls,
strings and lambdas containing commas, active parameter boundaries, explicit
invocation, inferred/explicit locals, destructuring policy, generic inferred
types, UTF-16 ranges, stale artifacts, cancellation, and separate capabilities.

**Exit criteria:** both capabilities use canonical compiler facts and either can
be disabled or reverted without affecting the other.

## R18: Optional Capabilities And Measured Optimizations

R18 is a staging area, not permission to bundle unrelated features. Each item
requires its own mini-roadmap, tests, capability flag, and process fixture.

- [ ] Add formatting by invoking the production formatter against the selected
      overlay and returning either no edits or one exact full-document edit.
      Preserve line endings, reject stale versions, and advertise formatting
      only after formatter parity fixtures pass.
- [ ] Design rename around compiler identities, prepare/rename validation,
      conflict detection, visibility, and versioned workspace edits. Never begin
      with textual replacement.
- [ ] Design code actions as transformations attached to compiler diagnostic
      codes and exact snapshots, not message-string matching.
- [ ] Design semantic tokens as a compiler-category projection with delta/full
      capability policy and deterministic token ordering.
- [ ] Add workspace symbols only after project-wide indexing has measured memory
      bounds and explicit partial-coverage behavior.
- [ ] Add file watchers only when they can feed typed catalog events through the
      R8 actor; they must not mutate disk layers from a watcher callback.
- [ ] Consider pull diagnostics only as a replacement protocol over the same
      committed diagnostics, not a second diagnostic engine.
- [ ] Measure typed-artifact reuse, finer invalidation, worker parallelism, and
      cooperative mid-typecheck cancellation separately. Adopt an optimization
      only with a representative benchmark and unchanged actor correctness
      tests.

**Exit criteria:** there is no aggregate R18 capability. An item leaves R18 only
when it has a standalone design, implementation slice, and independently honest
initialize advertisement.

## Explicit Non-Goals For Baseline Cutover

- Reproducing the OCaml initialize capability object.
- Preserving semantic method behavior through OCaml fallbacks.
- Incremental `didChange` ranges; full synchronization remains the baseline.
- A second parser, type inferencer, import resolver, formatter, or symbol naming
  scheme under `stage_12_lsp`.
- A worker pool, concurrent workspace mutation, or more than one active compiler
  analysis wave.
- Name-based navigation or references as a temporary implementation.
- Incremental typechecking seeded from prior typed artifacts or mid-expression
  cancellation before the production compiler exposes those APIs generally.
- Snippet completion, rename, code actions, semantic tokens, workspace symbols,
  file watchers, or pull diagnostics.
- An OCaml compatibility flag or an OCaml LSP process after R11.
- Analysis of non-`file:` editor buffers such as `untitled:` URIs. The baseline
  logs and ignores their synchronization notifications until virtual module
  identity is designed explicitly.
- Dynamically adding a project root when an editor opens a file outside all
  initialization roots. That requires an atomic source-catalog/configuration
  transition rather than borrowing the existing workspace's package settings.
