# Normalized Compilation Database Roadmap

**Status:** Active; Horizon 1 and Issues 61B, 68-73 implemented

**Scope:** One compiler invocation and the immutable products retained by an
LSP analysis snapshot. This is not a cross-run cache, an incremental build
cache, a process-global interner, or a request to replace every compiler tree
with a generic database.

**Current execution roadmap:**
[`NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md`](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md)
defines the next finite checkpoint: publish accepted semantic tables and edges,
replace the broad typed graph with recoverable/accepted/codegen-ready products,
and migrate compiler and tooling queries without retaining a parallel database.
This document remains authoritative for long-term identity, table, lifetime,
and migration invariants; the execution roadmap owns the current step order and
multi-metric acceptance gates.

**Near-term work:** Execute the
[Normalized Semantic Compilation Roadmap](NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md).
The completed module and definition identity checkpoints are prerequisites,
not active issues.

## Relationship To Current Documentation

This roadmap changes the proposed long-term ownership model; it does not
retroactively change current production truth.

- `docs/ARCHITECTURE.md` records the Stage 04-owned `ModuleTable` implemented by
  Issue 56. Issues 57-58 made that shared domain authoritative through Stage 06,
  CTFE, and Core graph lowering. External products remain descriptive where
  their protocol requires names and paths; internal typed call metadata and
  declaration identities are the next remaining normalization boundaries.
- `docs/COMPILER_PRIORITIES.md` remains authoritative for semantic
  typechecking phase decomposition, accepted/recoverable products, and
  demand-driven CTFE. Table normalization must follow those semantic
  boundaries rather than create a parallel typechecker.
- A rejected lexical-parameter batching experiment confirmed that transient
  `Env` and lexical scope state should not be pulled into the compilation
  database merely because it is expensive. The retained scalar scope-list
  cleanup is independent of the durable entity-table work below.

The new direction is not that the existing graph-local slot was secretly
durable. It is to make the issuing table a retained compilation product so a
new canonical `ModuleId` can remain meaningful through later phase products.
The old restriction explains why table ownership must be migrated first.

## Direction

The compiler should increasingly represent compilation entities as rows in
immutable, purpose-specific tables. Relationships between entities should be
represented by typed IDs and explicit edge tables rather than by copied names,
paths, nested owner records, or independently reconstructed dictionaries.

The intended shape is a normalized compilation database assembled
progressively during one compiler invocation:

```text
SourceTable
  SourceId -> source path, module spelling, text, line index

ModuleTable
  ModuleId -> resolved identity, canonical path, origin, SourceId

ModuleReferenceTable
  ModuleReferenceId -> importer ModuleId, source spelling, span

ModuleResolutionTable
  ModuleReferenceId -> resolved ModuleId or explicit unresolved outcome

DefinitionTable
  DefinitionId -> ModuleId, declaration kind, source name, source span

TypeDeclarationTable / CallableTable / GlobalTable / TraitTable / ImplTable
  category ID -> category-specific accepted facts

Relationship tables
  compact entity IDs -> compact entity IDs
```

Each compiler phase should consume an opaque product containing the exact
tables it is allowed to read and should publish new immutable tables for the
next phase. Earlier authoritative tables may remain referenced by later phase
products. A phase must not rediscover an earlier fact from source strings or
reconstruct an equivalent index if the authoritative table already contains
that fact.

This architecture has two goals:

1. reduce repeated hashing, string comparison, record copying, ARC traffic,
   repeated graph construction, and per-pass index construction; and
2. make compiler relationships directly queryable for diagnostics, analysis,
   and language tooling.

The second goal matters independently of performance. Once ownership,
visibility, imports, definitions, types, and references are explicit table
relations, compiler and LSP queries can follow exact edges instead of deriving
relationships from nested values and spelling conventions.

## Terms And Invariants

### Entity ID

An entity ID is an opaque integer whose value is meaningful only with the
table that issued it:

```blorp
opaque type ModuleId = Int
opaque type ModuleReferenceId = Int
opaque type DefinitionId = Int
opaque type CallableId = Int
```

Different entity families must not share one untyped integer API. A
`ModuleId` cannot be passed where a `DefinitionId` is required even if both
lower to the same C representation.

Within one compilation, an issued ID must remain stable. Rows are not
renumbered after publication. Rejection or dead-code elimination may produce
an outcome or liveness table, but it must not change the meaning of an existing
ID.

IDs are not stable across compiler invocations or independently constructed
analysis snapshots. Any product that retains an ID must retain or be
structurally tied to the corresponding table. Numeric equality across
unrelated tables is invalid.

### Entity table

An entity table owns one canonical row for each admitted entity of one kind.
Normally the dense row position is the entity ID. When a pre-existing
observable allocator has a nonzero base or proven gaps, the table may instead
use a named offset, explicit sparse slots, or a typed relation to a separate
dense row ID. That exception must be represented and measured; it cannot be
hidden behind a magic integer. A table is built under private, single-owner
construction and becomes immutable when published through an opaque phase
product.

A row should contain intrinsic facts about that entity. Facts that describe a
relationship between two entities belong in an edge table. For example, a
module's canonical origin belongs in the module row; an import from one module
to another belongs in module-reference and resolution tables.

### Edge table

An edge table records a relation between entity IDs. Examples include:

```text
ModuleReferenceId -> importer ModuleId
ModuleReferenceId -> resolved ModuleId
DefinitionId      -> owner ModuleId
CallableId        -> referenced DefinitionId
ImplId            -> implemented TraitId
TypeId            -> contained TypeId
```

The canonical edge rows are the source of truth. Dense adjacency lists or
reverse indexes are derived access paths and should be retained only for a
real measured or semantic consumer.

### Index

An index maps an external or non-dense key to an entity ID or ordered ID list.
Examples include resolved module identity to `ModuleId`, canonical path and
origin to `ModuleId`, and source name to candidate `DefinitionId` values.

Indexes must follow these rules:

- build the required index while building or validating its owning table;
- use the table as the source of truth and validate every index entry against
  its row;
- preserve source, overload, visibility, and newest-first ordering exactly;
- do not retain a reverse index without a concrete query;
- do not make a serialized string key when an already-resolved typed ID is
  available; and
- do not retain both a full descriptive owner and a parallel numeric owner on
  every row as a permanent migration state.

### Phase product

A phase product is an opaque capability to read a coherent set of tables. It
is not a generic bag of every compiler value. Its constructor validates table
lengths, foreign-key domains, ordering, accepted/rejected distinctions, and
provenance before publishing the product.

Conceptually:

```text
ResolvedCompilation =
  source tables
  syntax tables
  module table
  module-reference and resolution tables
  module-surface tables

TypedCompilation =
  ResolvedCompilation identity tables
  accepted definition/category tables
  typed body tables
  semantic reference tables
  diagnostics
```

The concrete Blorp representation should use narrow opaque products and
accessors. It should not introduce a public `Database` record that allows
arbitrary table combinations or makes every function depend on every phase.

### Transient state

Not every value belongs in the persistent compilation database. The following
are algorithm state and should ordinarily remain private and short-lived:

- lexer and parser cursors, stacks, and recovery frames;
- graph work queues and construction-only dedupe dictionaries;
- lexical scopes used while checking one body;
- inference metavariables, substitutions, expected types, and local
  refinements;
- CTFE evaluation stacks and mutable-local environments;
- pass-local rewrite state, ownership state, and traversal stacks; and
- backend string builders and rendering temporaries.

Transient state should consume stable entity IDs and publish immutable facts.
Persisting it would increase peak memory and blur the distinction between
accepted semantic facts and an unfinished computation.

## Lifetime Policy

The compiler may need the complete identity spine for the duration of one
compilation, but it should not retain every large phase snapshot
unconditionally.

The expected lifetime is:

| Table family | Minimum lifetime |
| --- | --- |
| Source identity and line mapping | Through final diagnostics; through the LSP snapshot for analyzed sources |
| Module, module-reference, and resolution tables | Entire compilation; through the LSP semantic snapshot |
| Definition ownership and stable semantic identity | Entire typed/Core compilation; through the LSP semantic snapshot |
| Tokens and trivia | Through parsing; longer only for formatter/LSP syntax clients |
| Parsed syntax | Through typechecking and source semantic projection; may end before late Core in compile-only mode |
| Accepted type/callable/global/trait/impl tables | Through CTFE and Core lowering; selected identity/projection tables may continue |
| Typed body tables | Through CTFE and Core lowering; through semantic snapshot projection where required |
| Core phase tables | From Core lowering through backend emission; obsolete phase snapshots should be released |
| Backend projection/layout tables | Through emission only |

Later products should retain earlier small identity tables when IDs still need
interpretation. They should not retain rich `Env`, typecheck-session state, or
every historical Core program merely because the IDs originated there.

This is a default policy, not an assumption that retention is free. Every
boundary that lengthens the lifetime of source text, syntax trees, typed
bodies, or Core expressions must measure peak RSS and retained objects.

## Current Architecture Findings

The current compiler already contains several pieces of this model, but they
are not yet one coherent compilation-owned database.

### Source and spans duplicate descriptive identity

`blorp/src/lib/source.brp` stores path and module name on `SourceFile`, and
every `SourceSpan` repeats path and module name alongside offsets and line/
column data. This is convenient and exact, but high-volume syntax and typed
trees repeatedly retain managed strings. A future `SourceId`/`SourceSpanId`
boundary is plausible, but it is intentionally not a near-term module-ID
issue because spans touch diagnostics, parser recovery, Core locations, JSON,
tests, and LSP UTF-16 conversion.

### Stage 04 owns the compilation module identity spine

`stage_04_modules/frontend_graph.brp` owns:

```text
ModuleTable: ModuleId -> ResolvedModuleIdentity
canonical path -> ModuleId index with exact row validation
ModuleId-aligned finalized program and ModuleSurface columns
List[FrontendModuleReference]
ModuleReferenceId -> resolution outcome
ModuleId -> ordered ModuleReferenceId list
```

Issue 56 established this as the single invocation-local module ID domain.
Stage 06 retains the same table with aligned prepared payloads; descriptive
replay requests reconstruct it once through the Stage 04 constructor. Module
and reference IDs are assigned in deterministic graph construction order, and
repeated source import occurrences retain separate reference rows.

`FrontendModule` remains only a compatibility projection assembled from the
stable identity row and aligned Stage 03/04 payloads. Issues 57-58 removed the
corresponding descriptive module owner fields from Stage 06, CTFE, and Core
graph transport.

### Stage 06 has table-like authorities but mixed ownership forms

Stage 06 already has graph-owned category authorities for types, aliases,
records, unions, callables, globals, traits, and implementations. It also has
a `DefinitionIndex`, module views, declaration skeletons, completed global
headers, checked body artifacts, and semantic occurrence projection.

These are useful domain-specific tables, but their keys and payloads still
mix:

- shared compilation-owned `ModuleId` values;
- canonical module-path strings at some type and external-projection boundaries;
- raw definition integers whose domain is implicit;
- managed structural declaration IDs that repeat module, source name, owner,
  and span; and
- source names repeated in category rows and owner indexes.

After Issue 43, accepted graph-owned declaration payloads are not copied back
into `Env`. Its remaining builtin, provisional, lexical, and body-session facts
are transient state and are not candidates for this database.

`TypecheckedModule` now retains one `ModuleId` rather than copied path, source
module name, canonical path, and complete `ModuleIdentity` fields. It still
retains parsed and typed programs, the module surface, diagnostics, import
bindings, and CTFE status in one row. `TypecheckedGraph` owns the shared
`ModuleTable`, one target row, and a module list. This is a materially cleaner
module transport, but it is still a rich payload product rather than a
definition/body/reference table product.

The current Stage 06 migration has measured an important representation rule:
one unboxed module integer on a hot declaration identity can materially reduce
allocations, while retaining one managed graph/scope carrier per declaration
can materially regress elapsed work. The shared table must therefore be owned
once by the containing product, not copied into every entity row.

### CTFE uses module and callable IDs but still reconstructs other entity contexts

Stage 07 receives complete `TypedProgram` values and constructs
`CtfeImportedProgram`, `CtfeContext`, `CtfeModuleGlobalEnv`, aliases,
constructor references, and function groups. Issue 58 made the module table and
module-aligned contexts authoritative. Issue 69 carries category-checked
`CallableId` values in resolved calls, retains the issuing `DefinitionTable`
once in the imported-program set, and derives callable ownership directly from
that table during CTFE translation. Global, nominal-type, field, trait, and
implementation identities remain later normalization cuts.

CTFE should eventually consume exact module, global, callable, constructor,
and body IDs plus accepted relationship tables. Its local evaluation
environment remains transient.

### Core lowering retains module ownership and definition-backed call owners

`stage_08_core_lower/graph_prepare.brp` now accepts `CoreGraphUnit` rows
containing one unboxed `ModuleId` and a complete `TypedProgram`. Its callable
registry uses a dense module-indexed outer list. Issue 69 makes resolved calls
definition-backed and requires the exact issuing `DefinitionTable` at the Core
graph boundary, so `lower.brp` derives callable owners without path-to-module
probes. It still projects canonical paths into UFCS/Core names at the existing
naming boundary, flattens module declarations into one `CoreProgram`, and
rewrites aliases.

The next clear migration boundary is therefore definition identity rather than
module transport. The lowerer should receive definition-backed callable IDs
directly and derive their owner through the retained definition table.
Canonical or C-safe names should continue to be projected once at an explicit
naming boundary rather than serving as the relation between modules, calls,
and definitions.

### Core is one nested rewrite value

Stage 09 represents the program as `CoreProgram { decls, foreign_includes }`.
Declarations, types, expressions, variables, and call targets are nested
values. Many passes accept and return a complete `CoreProgram`; several build
their own callable, type, union, layout, reachability, or ownership indexes.

Core already has useful integer identities such as definition IDs and static
string IDs, but many relations still use function/type names. Moving Core to
tables may remove repeated whole-program index construction and enable
row-local rewrites. It may also add indirection and harm traversal locality.
That tradeoff must be measured before a broad Core rewrite. Near-term work
should first preserve frontend IDs into Core and retain shared indexes with
demonstrated repeated consumers.

### Backend already uses several table products

Stage 10 has precedents including callable symbol plans, cancellation site/
owner/slot IDs, static string literal pools, and record layout registries. It
still wraps and rewrites a complete `CoreProgram`, and emission is primarily a
large traversal that creates C strings.

The backend should be the final materialization boundary for C names and text.
It should consume backend-ready entity/layout tables, produce symbol and
artifact tables, and concatenate/render only at artifact publication. It does
not need the rich frontend database once all required diagnostics and names
have been projected.

## Desired Stage Contracts

The contracts below describe what each phase should need, not permission to
rewrite every phase immediately. Fidelity is highest for Stages 04-06 and
decreases for later stages.

| Boundary | Dominant current product | Intended durable product | State that remains transient |
| --- | --- | --- | --- |
| Inputs/Stage 01 | Provider-owned source records and generated constants | Source rows selected for one invocation | Filesystem/package effects |
| Stage 02 | `LexResult` token/trivia lists with descriptive spans | Source-indexed token, trivia, and lexical-diagnostic tables | Lexer cursor and indentation/recovery stacks |
| Stage 03 | Nested `ParsedProgram` and opaque finalized wrapper | Parsed-module payloads plus syntax declaration/import locators | Parser/finalization stacks and worklists |
| Stage 04 | Partially normalized `FrontendGraph` | Canonical module, reference, resolution, root, and surface tables | Discovery queues and validation-only maps |
| Stage 06 | `IndexedGraph`, category authorities, `Env`, rich `TypecheckedGraph` | Definition/category/visibility/typed-body/reference tables keyed by `ModuleId` | Lexical scopes, inference metas, refinements, body-local diagnostics |
| Stage 07 | Typed-program wrappers and path/name keyed CTFE contexts | Exact CTFE work, value, dependency, and global-result tables | Evaluation stack and mutable-local environment |
| Stage 08 | `CoreGraphUnit` values and flattened `CoreProgram` | Module/definition keyed Core declaration tables, initially retaining expression trees | Lowering and naming rewrite state |
| Stage 09 | Rewritten whole `CoreProgram` per pass | Immutable Core snapshots and reusable analysis/relation tables | Pass traversal, rewrite, ownership, and worklist state |
| Stage 10 | Prepared `CoreProgram` and emission contexts | Layout, symbol, literal, cancellation, chunk, and artifact tables | C rendering buffers and emission temporaries |

### Stage 01: Generated Inputs

**Current responsibility:** Provide embedded standard-library source text and
compiler build metadata.

**Should consume:** Build-time generated constants only.

**Should produce:** Source-provider candidates that the compilation input
boundary inserts into the same `SourceTable` as disk, package, native, and
overlay sources. Stage 01 should not issue a parallel kind of module identity.

**Database role:** Provider, not owner. Embedded source names and contents are
inputs to source and module tables. Compiler version/build metadata belongs in
artifact metadata, not semantic entity rows.

### Compilation Input Boundary

This boundary is currently shared between CLI/package/LSP adapters and
`compiler/pipeline.brp`.

**Should consume:** Explicit roots, standard-library provider, package
configuration, native source metadata, source contents, command policy, and
analysis overlays.

**Should produce:**

```text
SourceTable
SourcePathIndex
CompilationConfiguration
RequestedRootSourceIds
```

`SourceId` should identify one selected source snapshot inside the invocation.
Overlay precedence must be resolved before the selected row is published.
Filesystem discovery, package policy, and effects remain adapter-owned.

### Stage 02: Lex

**Current input:** A complete `SourceFile` record.

**Current output:** `LexResult { tokens, diagnostics }`. Every token and trivia
entry carries source spans that repeat descriptive source identity.

**Should consume:** `SourceId`, source text, and an immutable line/index view.

**Should produce:**

```text
TokenTable          TokenId -> SourceId, kind, start/end offsets
TriviaTable         TriviaId -> SourceId, kind, start/end offsets
TokenTriviaEdges    TokenId -> ordered TriviaId values
LexDiagnosticTable SourceId -> diagnostics
```

Token IDs need only be stable through syntax construction. Formatter and LSP
requests may retain the token/trivia tables; ordinary compile-only requests
may release them after Stage 03 if no later diagnostic references token rows.

Lexer cursor, indentation stack, interpolation depth, pending trivia, and
recovery state remain transient.

**Deferred questions:** Whether line and column belong in every span row or
are derived from a per-source line-start table; whether token/trivia tables
improve memory versus the current compact nested values. Resolve with a
source-span allocation benchmark before implementation.

### Stage 03: Parse And Source Finalization

**Current input:** `SourceFile`. `parse_compiler_source` invokes `lex`
internally and initializes private parser state from the resulting token and
diagnostic lists; Stage 02 does not currently publish a separate pipeline
product to Stage 03.

**Current output:** A nested `ParsedProgram` containing source, declarations,
expressions, spans, and diagnostics. Finalization rewrites interpolation,
nested functions, and subscript reads and exposes an opaque
`FinalizedTypecheckProgram` over the same broad AST representation.

**Should consume:** `SourceId`, token/trivia tables, and parser policy.

**Nearer-term output:**

```text
ParsedModuleTable        SourceId -> finalized ParsedProgram payload
SyntaxDeclarationTable  SyntaxDeclId -> SourceId, declaration kind, span, locator
ImportSyntaxTable        ImportSyntaxId -> SourceId, requested path, aliases, selections, span
ParseDiagnosticTable    SourceId -> diagnostics
```

The first migration should index existing immutable AST payloads rather than
immediately flatten every expression. `ModuleSurfaceSymbolSource` already uses
decoded declaration and method positions; typed opaque syntax IDs would make
that relationship explicit without guessing by name.

**Possible later output:** `SyntaxExprId`, `PatternId`, `TypeSyntaxId`, and
their child-edge tables. This is lower-confidence work. The parser's recursive
construction and diagnostics may be clearer and faster with local trees, so a
fully normalized syntax arena requires independent allocation/locality data.

Parser state, recovery frames, precedence stacks, and finalization worklists
remain transient.

### Stage 04: Module Discovery, Surface, And Resolution

**Current input:** Root and seed source candidates plus a resolution callback.

**Current output:** `FrontendGraph` with a Stage 04-owned `ModuleTable`,
`ModuleId`, `FrontendModuleReferenceId`, roots, aligned finalized-program and
surface columns, reference rows, exact resolution outcomes, and per-module
ordered reference IDs.

**Should consume:** Source and parsed-module tables, root `SourceId` values,
package/module resolution policy, and accepted parser state.

**Should produce the compilation identity spine:**

```text
ModuleTable
  ModuleId -> ResolvedModuleIdentity and SourceId

ModuleIdentityIndex
  exact resolved identity -> ModuleId

ModulePayloadTable
  ModuleId -> finalized syntax/module-surface row IDs

ModuleReferenceTable
  ModuleReferenceId -> importer ModuleId, ImportSyntaxId/requested path/span

ModuleResolutionTable
  ModuleReferenceId -> resolved ModuleId or explicit unresolved outcome

ModuleReferenceAdjacency
  ModuleId -> ordered ModuleReferenceId values

RootModuleIds
ModuleSurfaceTable / ModuleSurfaceSymbolTable
```

Stage 04 owns the only `ModuleTable` constructor and `ModuleId` domain. Normal
graph construction assigns IDs while discovering and validating modules and
populates the required indexes in the same construction. A sanctioned
self-contained replay decoder reconstructs its table by invoking that same
Stage 04-owned constructor; it is not a second issuer or namespace. Later
stages may append phase-specific payload tables aligned to `ModuleId`, but they
must not mint another module-ID namespace.

Duplicate identity, origin, path, root, missing importer, missing target, and
repeated import-occurrence behavior remain exactly as today. Unresolved
references are rows with explicit outcomes, not absent edges or magic IDs.

### Stage 05

There is no `stage_05_*` production directory. Foundational type-system and
environment code lives under Stage 06. This roadmap does not propose
renumbering source directories merely to make the database diagram contiguous.

Conceptually, accepted declaration indexing and semantic preparation form the
next database layer after Stage 04. Their current and target ownership are
described under Stage 06.

### Stage 06: Binding, Typechecking, And Semantic Projection

**Current input:** A validated `FrontendGraph` in the direct path, or a
descriptive `TypecheckGraphRequest` in the replay boundary. The direct path
passes the exact Stage 04 `ModuleTable` into `IndexedGraph`; replay constructs
one table through the same Stage 04 owner. Prepared, bound, skeleton,
environment, accepted-authority, and typed-module ownership is aligned to the
shared `ModuleId` domain. Descriptive identities remain at replay, diagnostic,
semantic-projection, and source-spelling boundaries.

**Current output:** Rich `TypecheckedModule` and `TypecheckedGraph` values,
plus graph-owned authorities, prepared environments, completed headers,
checked body artifacts, diagnostics, semantic occurrences, and a definition
ID frontier.

**Should consume:**

- the Stage 04 `ModuleTable`, module/reference/resolution tables, and module
  surface tables;
- parsed declaration locators and source spans;
- compiler builtin/language-surface tables;
- command policy such as debug-only admission and requested target IDs; and
- replay input normalized once into the same table form at the replay decoder
  boundary.

**Should produce:**

```text
DefinitionTable
  DefinitionId -> ModuleId, source declaration locator, kind, name, span,
                  visibility

TypeDeclarationTable
CallableTable
GlobalTable
TraitTable
ImplementationTable
ConstructorTable
FieldTable

Declaration relationship tables
  type -> constructors
  record/union -> fields
  trait -> methods/supertraits
  impl -> trait/type/methods
  callable/global -> owner module

ModuleVisibilityTables
  module -> local/selective/qualified/prelude definition IDs

TypedBodyTable
  DefinitionId -> accepted typed body or explicit rejected outcome

SemanticReferenceTable
  reference occurrence -> exact DefinitionId/exported identity, source span

TypecheckDiagnosticTable
RejectedDeclarationTable
  source declaration locator -> explicit rejection/recovery outcome

DefinitionId frontier and generated-definition provenance
```

Category tables should contain category-specific facts once. Module views
should contain ordered IDs/locators, not copied signatures or complete owner
records. Exact lookup should first establish the table/provenance domain, then
use integer addressing and compare only the fields required by that query.

`Env`, lexical `Scope`, metas, substitutions, body-local variables,
refinements, expected return type, and local diagnostics remain body-session
state. They should read accepted tables and publish checked artifacts; they
are not persistent database tables.

**Type representation:** Mutable inference types and `SemanticMetaType` cannot
be globally interned safely while unification is in progress. A future
accepted `SemanticTypeTable` should be considered only after solving and
canonicalization, with structural child IDs and no unresolved metas. Parsed
type syntax and session-local inferred types remain distinct domains.

**Failure products:** Parser recovery, rejected declarations, and recoverable
body outcomes remain representable for diagnostics and LSP, but they cannot
inhabit accepted semantic/category tables. The phase product, rather than a
status Boolean on every row, should prove which tables are accepted for CTFE
and Core lowering.

### Stage 07: Compile-Time Evaluation

**Current input:** Retained `ModuleTable` and `DefinitionTable` authorities,
module-ID-keyed typed programs and imported-program wrappers, import bindings,
definition-backed resolved callable IDs, and reconstructed
function/global/constructor contexts. CTFE derives graph-call ownership from
the canonical definition row rather than converting a stored module path back
to `ModuleId`. Production currently invokes Stage 07 helpers from the Stage 06
bridge while assembling the final typed graph; the numbered boundary is not
yet a standalone top-level pipeline product.

**Current output:** Evaluated global environments and rewritten typed global
initializers, with fallback and materialization metrics.

**Should consume:**

- `ModuleId`, `DefinitionId`, `GlobalId`, `CallableId`, and `ConstructorId`;
- accepted typed body and global initializer rows;
- exact call/reference/import edges;
- type rows required to validate materialization; and
- an explicit deterministic CTFE root/worklist table.

**Should produce:**

```text
CtfeWorkTable
  DefinitionId -> unseen/queued/checking/accepted/rejected state

CtfeValueTable
  CtfeValueId -> immutable value payload and accepted type ID

CtfeGlobalResultTable
  GlobalId -> materialized CtfeValueId or explicit runtime/failure outcome

CtfeDependencyEdges
  CTFE root/body/global -> exact referenced entity IDs

TypedBodyOverrideTable or materialization projection
  GlobalId -> rewritten initializer payload
```

The CTFE evaluator's local bindings, mutable-local values, call stack, and
loop state remain transient. Module and definition relations should not be
reconstructed from path/name strings or by scanning complete imported typed
programs.

The existing demand-driven CTFE roadmap remains the semantic sequencing
authority. Database normalization should support it, not create a parallel
CTFE body scheduler.

### Stage 08: Core Lowering

**Current input:** One retained `ModuleTable`, a target `ModuleId` and
`TypedProgram`, a list of `CoreGraphUnit { module_id, typed_program }`, import
binding strings, include directories, and the definition-ID frontier. Typed
call metadata still contains canonical owner paths that lowering resolves back
to module IDs.

**Current output:** One flattened `CoreProgram` with module names prefixed into
declaration strings, callable aliases rewritten, FFI boundaries annotated,
list layouts selected, and an updated definition frontier.

**Should consume:**

- the retained `ModuleTable` and selected `ModuleId` values;
- accepted definition/category and typed-body tables;
- CTFE global materialization results;
- exact import, call, callable, and global-reference edges; and
- one generated-definition allocator/domain.

**Initial target output:**

```text
CoreModuleTable
  CoreModuleId/ModuleId -> lowered declaration ranges and import edges

CoreDefinitionTable
  CoreDefinitionId -> source DefinitionId or explicit generated provenance

CoreFunctionTable / CoreGlobalTable / CoreNominalTypeTable
CoreCallableEdges / CoreGlobalReferenceEdges
CoreProgramRoots
CoreForeignIncludeTable
```

Module ownership should remain an ID relation. Source names and canonical
paths should not be prefixed into semantic Core names merely to recover
ownership later. C-safe names belong in Stage 10's symbol projection.

**Deferred expression representation:** The first Stage 08 cut should allow
rows to retain existing `CoreExpr` trees. A `CoreExprId` arena and child-edge
tables should be considered only after measuring repeated expression copying,
index construction, and traversal locality. This keeps the module/definition
normalization separable from a broad Core IR rewrite.

### Stage 09: Core Transformations

**Current input/output:** Most passes consume and return a complete nested
`CoreProgram`. They repeatedly traverse declarations and expression trees and
often construct pass-specific type, callable, union, reachability, layout, or
ownership indexes.

**Should consume:** A phase-specific immutable Core snapshot with stable
definition/entity IDs and the exact indexes proven useful by earlier passes.

**Should produce:** A new immutable Core snapshot plus new analysis tables.
Unchanged entity rows should be shared. Newly synthesized or specialized
definitions append rows with explicit generated provenance. Existing IDs must
not be renumbered.

Potential table families include:

```text
CoreTypeTable
CoreFunctionTable
CoreGlobalTable
CoreNominalTypeTable
CoreExpressionTable             (only if measured)
CoreCallEdges
CoreTypeUseEdges
CoreReachabilityTable
CoreRepresentationTable
CoreOwnershipTable
CoreReusePlan
CoreClosureCaptureEdges
CoreResourceCleanupTable
```

The pass sequence remains semantically authoritative. Table architecture does
not permit reordering match lowering, trait resolution, call resolution,
specialization, DCE, Perceus, reuse, closure conversion, resource management,
fairness, or final preparation.

High-confidence early opportunities are shared definition/callable/type
indexes that several adjacent passes currently rebuild. Lower-confidence work
is flattening all `CoreExpr` trees. Integer list access is not automatically
faster if it destroys locality or causes whole-list COW updates, so every Core
table tranche requires generated-C, locality, and allocation evidence.

For DCE, removed rows should be represented by a liveness/reachability product
or by a final compact backend projection. Renumbering surviving semantic IDs
mid-pipeline is not acceptable.

### Stage 10: Backend Projection And Emission

**Current input:** A prepared `CoreProgram` plus compile policy and runtime
sources.

**Current products:** Callable C-symbol projection, static string literals,
record layouts, cancellation plans, prepared renderer operations, emitted C,
link flags, include directories, and final `BuildArtifact`.

**Should consume:** Only backend-ready Core tables, representation/ownership
tables, source locations required for internal errors, and artifact policy.

**Should produce:**

```text
CTypeLayoutTable
CCallableSymbolTable
CGlobalSymbolTable
CStaticLiteralTable
CCancellationPlan
CDeclarationChunkTable
CArtifact
BuildArtifact
```

This is the normal boundary where descriptive C names and final strings are
materialized. Symbol assignment should use stable definition IDs and explicit
ABI/export requirements. Emitters should read tables; they should not rescan
the program to rediscover callable ownership, type layout, reachability, or
cancellation behavior.

The final artifact is intentionally denormalized text and command metadata.
There is no value in retaining compiler entity tables after artifact
publication unless a caller separately requested diagnostics, observations,
or an analysis snapshot.

### Tooling And LSP Snapshots

Formatter, purify, lint, tests, and LSP do not all need the same phase product.
They should select an explicit product rather than retain a universal mutable
compiler state.

The LSP should retain at least:

- selected source rows and line/UTF-16 mapping;
- module, module-reference, and exact resolution tables;
- definition ownership/kind/name/span tables;
- semantic definition/reference occurrence tables;
- visibility and completeness facts required by each capability; and
- diagnostics for the exact analyzed revision.

It should not retain typecheck `Env`, inference metas, CTFE evaluation stacks,
or Core programs merely to support navigation. IDs are snapshot-local, so a
workspace commit must atomically publish the table set and its revision proof.
Cross-snapshot comparison uses durable source/module identity at the admission
boundary, then queries the selected snapshot by IDs.

## Construction And Validation Rules

Every table-building phase should follow the same narrow pattern:

1. Establish deterministic input order from the preceding accepted product.
2. Append each admitted row exactly once under private unique ownership.
3. Assign the typed ID from the row position or explicit monotonic allocator.
4. Populate required indexes and edge rows in the same traversal where doing
   so does not perturb source/identity order.
5. Validate foreign IDs, exact table lengths, duplicate policy, and ordering.
6. Publish one opaque immutable phase product.
7. Release construction-only maps and queues.

The table constructor must fail closed. It must not return a partially valid
table with a Boolean saying that some rows should be ignored.

When one logical relationship needs multiple query directions, first retain
one canonical edge table. Add adjacency/reverse indexes only with a named
consumer and a benchmark or deterministic work argument. Issue 16's dictionary
experiments and the Stage 06 module-ID work both show that additional managed
indexes can cost more than the lookup they replace.

## Diagnostics And External Identity

Diagnostics must remain byte-for-byte and order equivalent throughout the
migration. Internal diagnostics may retain IDs and source spans, but rendering
must resolve them through the owning tables before the phase product is
released.

No error path may depend on an invalid table lookup. Unresolved module
references, rejected declarations, synthetic/compiler-owned definitions, and
anonymous/direct programs need explicit variants or legitimate table rows.
Magic negative IDs, hashes used as IDs, and path-prefix heuristics are
forbidden.

External formats may remain descriptive:

- replay JSON must be self-contained and normalize into tables once on decode;
- diagnostics render paths, names, and source positions;
- LSP protocol values render URIs, ranges, and stable capability identities;
- C emission renders ABI symbols; and
- debug JSON may materialize complete rows.

These projections do not justify carrying descriptive identity through every
internal edge.

## Migration Method

### Vertical cuts, not a second compiler

Each issue must move one authoritative relationship from descriptive values to
IDs, migrate its complete production consumers, and delete the superseded
internal representation. Temporary comparison surfaces are allowed only for
measurement and must be removed before commit unless they are compact,
reviewed, durable benchmark infrastructure.

Do not build a complete parallel compilation database beside the current
pipeline. That would retain both representations, increase peak memory, and
make semantic drift likely.

### Compatibility boundaries

External and graphless entry points may normalize descriptive inputs once.
Compatibility adapters must be narrow and temporary where possible. A public
constructor that accepts arbitrary rows and can forge table provenance is not
acceptable.

Replay, direct-program tests, compiler surfaces, and anonymous modules need
explicit construction paths. They are not reasons to keep descriptive
identity in every production row.

### Fast feedback loop

For each tranche:

1. Record exact current constructors, readers, writers, equality rules, and
   ordering rules.
2. Add structural tests that fail before the representation change.
3. Add a deterministic fixture varying entity count, edge density, duplicate
   names, graph shape, and existing table size as relevant.
4. Compare semantic checksums, diagnostics, ID order/frontier, and all logical
   counters exactly.
5. Inspect generated C for unboxed IDs, one table construction, and absence of
   unintended per-row graph/table retains.
6. Run focused stage tests and leak/sanitizer coverage for changed ownership
   boundaries.
7. Compare at least three alternating production replay pairs when the path is
   materially exercised; require byte-identical responses and allocator/RSS
   data.
8. Ratchet retired descriptive operations in source and, where available,
   exact function instrumentation.

Useful logical counters include:

- table rows published;
- edge rows published;
- unique and non-unique index entries;
- descriptive identity materializations;
- string storage-key constructions and dictionary probes;
- integer table reads;
- table/snapshot publications; and
- pass-local indexes constructed and discarded.

Wall time alone is not sufficient. Allocation/release/current-object/byte
counts, retired instructions, peak RSS, and generated representation are the
primary evidence for mechanical normalization.

### Acceptance policy

An enabling issue may be accepted with neutral whole-compiler timing if it:

- deletes real reconstruction or duplicate ownership;
- keeps allocator/RSS behavior neutral or better;
- has an immediate production consumer;
- makes a later cut mechanical rather than speculative; and
- does not retain two authoritative representations.

Issues 56-58 formed the completed module-identity checkpoint. Issues 68-73 form
the next cumulative definition-identity checkpoint. Each new issue must remove
an old authority or a measured reconstruction in the same cut; by the end of
Issue 73 the combined state must show a repeatable reduction in managed
declaration-identity traffic, serialized identity keys, per-expression module
path probes, allocations, or retired instructions. A negative result must be
recorded and the offending representation change removed rather than justified
solely by architecture.

## Sequenced Roadmap

Fidelity intentionally decreases with distance. Near-term issues name exact
boundaries and tests; later horizons state hypotheses that require a fresh
audit before implementation.

### Horizon 1: One module identity spine (high fidelity)

1. **Issue 56: Establish one compilation module table (implemented).** Extract one
   Stage 04-owned `ModuleId` domain and immutable identity table, retain exact
   module-reference/resolution rows, and make direct and replay Stage 06 entry
   normalize into that shape. Do not yet migrate declaration identities.
2. **Issue 57: Make module IDs authoritative through Stage 06 (implemented).** Remove the
   independent `PreparedModuleId` domain, align prepared/bound/module-view/
   environment payloads to the Stage 04 table, and migrate remaining
   graph-backed declaration owner fields where the owning table is retained.
   Materialize descriptive identity only for diagnostics and external
   semantic projection.
3. **Issue 58: Carry module IDs through CTFE and Core lowering (implemented).** Replace
   module-path/name transport in typed graph, CTFE imported contexts, and
   `CoreGraphUnit` with table-backed IDs at the bounded phase boundaries.
   Keep C name projection later and retain current expression/typed-program
   payloads initially.

These issues are sequential. Issue 57 must not invent a second table while
Issue 56 is unsettled, and Issue 58 must not serialize or independently rebuild
the ID domain.

The completed Horizon 1 checkpoint removed descriptive module join fields and
path-keyed CTFE/Core relations while preserving byte-identical replay output.
Issue 58 measured neutral whole-compiler cost (+0.0003% allocations, -0.14%
peak RSS, +0.78% median elapsed); this is enabling normalization rather than a
compiler-wide speedup. Horizon 2 changes must identify and measure a concrete
consumer of the normalized ID spine.

### Horizon 2: Stage 06 entity tables (high to medium fidelity)

Horizon 2 has one table foundation followed by six bounded identity cuts:

1. **Issue 61B: Establish the canonical graph definition table (implemented).**
   Turn the production `DefinitionIndex` allocation entries into one immutable
   table of graph-owned definition rows plus owner/name indexes. Preserve the
   exact existing allocation frontier and make builtin, graphless, and rejected
   provenance explicit. Retire the benchmark-only `AcceptedDeclarationCatalog`
   if its required reachability audit still finds no production reader; do not
   add a second declaration catalog. The completed cut selected a dense table
   with an explicit graph base after proving that every production extension is
   append-only; it also deleted the dormant catalog and its private harnesses.
2. **Issue 68: Use scalar definition IDs for constructor identity (implemented).**
   Replace the managed structural/runtime constructor identity with a
   table-scoped, category-checked scalar ID. Materialize canonical
   owner/name/span facts only from the issuing `DefinitionTable`.
3. **Issue 69: Make resolved calls definition-backed (implemented).**
   Replace managed callable identity records, raw direct-call integers, and
   imported/implementation-method module-path metadata with scalar callable
   IDs backed by the definition table. CTFE and Core lowering derive the owner
   module from the table and delete per-expression path-to-ID probes. The
   completed cut also replaced a modules-times-callables body-planning scan
   with contiguous per-module ranges over the canonical callable list.
4. **Issue 70: Make nominal type IDs definition-backed (implemented).**
   Replace `TypeIdRep { module_id, name, span }` and its serialized storage keys
   with a category-safe scalar definition ID. Cut accepted alias, record, and
   union authorities over in the same issue so the old managed identity does
   not survive beside the new one.
5. **Issue 71: Make global IDs definition-backed (implemented).**
   Claim the already reserved global definition row, replace structural
   `GlobalId`, remove duplicate raw IDs from accepted graph bindings, and make
   exact accepted-global lookup integer-addressed.
6. **Issue 72: Make field IDs definition-backed (implemented).**
   Replace raw optional field definition integers with `FieldId`, publish the
   exact field-to-parent-type relation once, and thread typed field identity
   through inference and semantic occurrences.
7. **Issue 73: Normalize trait and implementation identities (implemented).**
   Scalarize graph trait and implementation IDs, give compiler builtins an
   explicit identity domain, compact trait method identity, and consolidate
   relationship/module-view indexes around named production queries.

Issue 61B establishes the table foundation and Issue 68 establishes the scalar
constructor precedent. Issues 69, 70, and 71 are
conceptually independent after it, but they share Stage 06 skeleton/projection
files and should be integrated one at a time unless separate worktrees prove
their diffs do not overlap. Issue 72 follows Issue 70. Issue 73 follows all
earlier cuts and closes the declaration-identity checkpoint.

This horizon must coordinate with the typechecking phase-product roadmap.
Database normalization must not make unfinished body state look accepted,
retain the benchmark-only `AcceptedDeclarationCatalog` as a second authority,
or reintroduce broad mutable `TypecheckState` ownership. Checked-body and
semantic-occurrence tables remain later Horizon 2 work after the six identity
cuts have been measured.

### Horizon 3: Accepted type and CTFE normalization (medium to low fidelity)

Investigate:

- interning solved, canonical semantic types after all metas are resolved;
- type child-edge, containment, trait-bound, and implementation-match tables;
- exact CTFE callable/global/constructor worklists by ID;
- CTFE value tables and global materialization outcomes; and
- removal of complete imported-program scans and path/name contexts.

Do not intern mutable inference types or use structural hashes as identity.
The accepted type table must prove canonicalization and preserve all existing
diagnostic spellings and nominal ownership.

### Horizon 4: Core declaration and relation tables (lower fidelity)

First preserve module and definition IDs through lowering. Then identify
indexes rebuilt by multiple adjacent Core passes and promote only those with
clear ownership and reuse. Candidate first tables are functions, globals,
nominal types, callable edges, type-use edges, and reachability.

Only after that evidence should the project consider a `CoreExprId` arena.
The experiment must compare traversal locality, COW behavior, allocations,
retained bytes, and pass complexity against current immutable expression
trees.

### Horizon 5: Table-native transformations and backend (exploratory)

Possible endpoint:

- Core passes publish immutable delta/replacement tables sharing unchanged
  rows;
- specialization and synthesis append explicit generated rows;
- DCE publishes liveness and a compact backend projection without changing
  semantic IDs;
- ownership, reuse, closure, resource, and cancellation facts are explicit
  side tables; and
- backend symbol/layout/chunk tables feed a single rendering boundary.

This endpoint is a direction, not an approved rewrite. It requires new
benchmarks and a pass-by-pass dependency audit once Horizons 1-3 establish the
actual gains and costs of normalized table access in generated C.

## Known Risks

### Retaining too much

A cumulative product that keeps token streams, parsed trees, typed trees,
every Core snapshot, and all indexes until emission could increase peak RSS
substantially. Retain stable identity tables broadly; retain large payloads
only through their last consumer.

### COW table updates

Appending to a shared immutable list can clone storage. Builders must retain
unique ownership until publication. Transformations should build a new table
or share unchanged row payloads rather than repeatedly update a shared list.

### Indirection and locality

List indexing is cheaper than hashing, but an arena of small separately owned
records can be slower than walking one local tree. Generated C and production
measurements decide whether expressions and types should be flattened.

### Provenance leakage

A bare integer crossing into a product with the wrong table causes silent
misidentification. Opaque products, narrow constructors, exact length/domain
validation, and snapshot ownership are mandatory.

### Parallel old and new representations

Adding IDs while retaining complete owner records on every entity can increase
allocations and memory. The Stage 06 experiments already demonstrated this.
Each cut must remove the old hot representation or remain an explicitly
temporary measurement candidate.

### Synthetic and graphless entities

Compiler builtins, direct programs, anonymous modules, generated Core
definitions, recovery artifacts, and replay requests do not all originate in
the normal Stage 04 graph walk. Each needs a legitimate row/provenance path or
an explicit separate identity variant. Magic IDs are prohibited.

### Observable order

Module discovery, declaration allocation, overload resolution, newest-first
scope history, diagnostics, imports, CTFE work, and Core declarations all have
observable or tested order. Dense tables must preserve those orders rather
than sorting for implementation convenience.

## Design Decisions And Open Questions

Issues 56-58 resolved the module-table decisions recorded below. The remaining
questions are assigned to the named horizon and must be answered from a current
code audit and measurement rather than treated as settled architecture.

### Module table payload

Issue 56 resolved this for the current horizon: `ModuleTable` owns canonical
`ResolvedModuleIdentity` rows and their indexes. Finalized programs, module
surfaces, prepared modules, typed programs, and environments remain aligned
phase payloads rather than fields of the identity row. A future `SourceId`
relation remains separate work.

### Table compatibility proof

Issues 56-58 use opaque product construction plus exact structural module-table
compatibility at rare cross-product admission points. IDs remain unboxed and
carry no managed provenance. Later tables should follow that pattern unless a
focused measurement demonstrates that structural admission checks are hot
enough to justify a compact product token.

### Compiler-owned and graphless rows

Issues 56-58 gave direct programs, anonymous modules, and replay inputs
sanctioned Stage 04 table construction paths. Compiler builtins still occupy
the definition allocator below the graph-owned frontier, and generated Core
definitions are a later phase-specific domain. Issue 68 must represent that
boundary explicitly: graph definition rows may use a named base/frontier or a
provenance variant, but no issue may use a magic numeric ID or an empty module
path as a sentinel.

### Definition ID density

Stage 06 and Core share observable definition-allocation behavior, but raw
definition integers can collide across independently built products and may
contain gaps through the current explicit insertion API. Issue 68 must audit
normal graph construction, direct/graphless extension, replay, compiler
builtins, and tests before choosing one of three explicit layouts: a contiguous
graph-owned slice with a named base, an option-valued sparse slot table, or a
separate dense row ID plus exact runtime-definition relation. Preserve claim
order and the final frontier; do not assume that a test-supported gap is a
production requirement or silently renumber observable IDs.

### Source and span normalization

`SourceSpan` is a likely high-volume normalization target, but replacing its
path/module strings affects every diagnostic and protocol boundary. A future
issue must measure retained string/span allocations and compare direct line/
column storage with `SourceId + offsets + line-start index` before choosing a
schema.

### Accepted semantic type table

It is not yet known whether structurally interning accepted semantic types
will improve enough equality/copy work to offset hash construction and
indirection. Unresolved metas and session-local type variables cannot enter
that table. Horizon 3 needs an isolated solved-type workload and a proof of
canonical nominal ownership.

### Core expression arena

The current nested `CoreExpr` representation gives direct tree locality but
causes broad immutable rewrites. A row/edge arena may share unchanged nodes and
support relational analyses, or it may add list lookups and COW table updates
to every traversal. Horizon 4 must compare both shapes on representative pass
pipelines before establishing `CoreExprId` as architecture.

### Snapshot persistence

Compiler-only execution can release tokens, syntax, typed bodies, and older
Core snapshots at their last use. LSP analysis needs selected source, module,
definition, occurrence, and completeness tables for a revision. A future LSP
issue must define the minimum snapshot table set and prove that no inference
or Core state is retained accidentally.

## Completion Criteria

This roadmap is successful when:

1. one `ModuleId` domain is issued during Stage 04 and remains authoritative
   through typechecking, CTFE, Core lowering, and semantic tooling snapshots;
2. later entity tables carry `ModuleId` foreign keys instead of copied module
   identities and paths;
3. every accepted definition, type, callable, global, trait, implementation,
   and relevant occurrence has one authoritative table row;
4. import, ownership, visibility, containment, call, and reference relations
   are explicit typed edges;
5. transient parser/inference/pass state remains separate from accepted
   immutable products;
6. external strings are materialized at diagnostics, protocol, debug, and C
   emission boundaries rather than used as dominant internal identity;
7. repeated per-phase reconstruction and indexes have materially declined;
8. compile responses and diagnostics remain exact; and
9. production measurements demonstrate lower instructions, allocations, or
   retained memory without material latency or RSS regression.

The endpoint is not "everything is an integer." The endpoint is that every
integer names one authoritative immutable row, every relationship has an
explicit owner, and every phase receives only the facts it needs.
