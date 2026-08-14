# Typechecking Architecture Roadmap

Status: active. Phases 0 through 3 are complete. Phase 4 is the next migration
boundary.

Last revalidated: 2026-08-13 against production graph, CTFE, standalone, and
accepted-header import paths after Phase 3 closure.

Scope: the Blorp-owned module binding, declaration header, body inference,
validation, CTFE scheduling, and typed-graph pipeline. This roadmap does not
add source-language features, persistent caches, parallel typechecking, or new
OCaml implementation work.

This is the execution roadmap for typechecking architecture and performance.
Use:

- [ARCHITECTURE.md](ARCHITECTURE.md) for the current production pipeline;
- [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for broader compiler priorities;
- [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md) for removing
  the remaining OCaml host and tools; and
- this document for typechecker phase contracts, implementation order, tests,
  benchmarks, and merge checkpoints.

## Objective

Turn typechecking from a broad stateful procedure into a sequence of explicit,
independently testable phase products:

```text
CompilerIndexedGraph                         [complete]
    -> CompilerBoundModuleGraph              [Phase 2]
    -> CompilerDeclarationSkeletonGraph      [Phase 3B]
    -> CompilerAcyclicTypeAliasDependencyGraph [Phase 3C complete]
    -> CompilerResolvedTypeParameterGraph    [Phase 3C complete]
    -> CompilerTypeHeaderGraph               [Phase 3C complete]
    -> CompilerDeclarationHeaderGraph        [Phase 4]
    -> CompilerHeaderCompletionOutcome       [Phase 5]
    -> CompilerHeaderGraph                   [Phase 5 success]

CompilerHeaderGraph + CompilerBodyCheckContext
    -> CompilerInferredBody                  [Phase 8 internal product]
    -> CompilerSolvedBody                    [Phase 8 success]
    -> CompilerValidatedBody                 [Phase 9 success]
    -> CompilerCheckedBodyArtifact           [stable body-check facade]

headers + body artifacts + CTFE outcomes
    -> CompilerCheckedGraph                  [Phase 10]
    -> CompilerCodegenReadyGraph             [Phase 10 success]
```

The phase numbers are the migration order, not a claim that CTFE is a semantic
transformation between inference and solving. Phase 6 first establishes an
independent body-check facade that preserves all current inference, solving,
and validation behavior. Phase 7 schedules that complete facade on demand.
Phases 8 and 9 then decompose how the same accepted body artifact is constructed
internally. CTFE never consumes a raw `CompilerInferredBody` or
`CompilerSolvedBody`.

The architecture must make these invalid states unrepresentable:

- an import binding whose optional fields disagree about its kind;
- a semantic import reconstructed independently by every importer;
- a declaration identity paired with a parsed declaration of another category;
- a trait bound whose identity is only a spelling after name resolution;
- a usable global header whose type is actually a pending sentinel;
- a body that mutates graph-wide semantic facts while being checked;
- a solved body containing inference metavariables;
- a rejected body presented to Core as accepted; and
- a CTFE dependency body inferred repeatedly when one accepted artifact can be
  shared.

## Decisions Locked For This Roadmap

These decisions should not be reopened inside an implementation slice without
new correctness evidence or representative measurements.

1. **Phase products replace validity flags.** Accepted, pending, and rejected
   states use distinct variants or opaque products. A record with optional
   later-phase fields is not a phase boundary.
2. **Semantic facts belong to definitions.** Types, callable signatures,
   traits, implementations, globals, and bodies are resolved once for their
   defining module. Imports bind stable identities and visibility; they do not
   replay parsed declarations.
3. **Graph facts are immutable during body checking.** Body-local scopes,
   metavariables, substitutions, local IDs, expected types, and diagnostics
   belong to a fresh inference session.
4. **Diagnostics recovery and codegen readiness are different products.** Tools
   may inspect rejected bodies. Core may receive only a graph whose required
   headers and bodies are accepted.
5. **Checks stay at the earliest sound phase.** Extraction must not postpone a
   lexical or inference-time safety check merely to make validation look more
   uniform.
6. **Stable identities precede indexing and optimization.** No semantic lookup
   may depend on display names, source formatting, or guessed declaration
   shapes after its identity phase exists.
7. **All header dependencies receive skeleton identities first.** Type
   declarations may have trait-bounded parameters, so type, constructor, trait,
   trait-method, callable, global, and implementation skeleton identities are
   reserved before full type or callable headers are resolved.
8. **Parsed source provenance is explicit but not semantic state.** Later
   phases still need declaration annotations and bodies. Associate each stable
   identity with a category-aligned source variant or source locator; never use
   a raw parsed declaration list as a resolved module/header interface.
9. **No caches in this roadmap.** First eliminate repeated semantic work by
   construction. Persistent or cross-compilation caching is a later design.
10. **No parallel typechecking in this roadmap.** First prove that body checking
   is independent, deterministic, and ownership-safe. Parallel execution is a
   later measured option.
11. **Mechanical extraction must reduce ownership ambiguity.** Do not create
   wrapper-only modules or split mutually recursive inference code across files
   merely to reduce line counts.
12. **Optimization checkpoints may conclude with no retained code change.** A
    measured regression or noise-level result is evidence, not a reason to
    preserve complexity.
13. **Production and benchmarks use the same APIs.** Benchmark-only duplicate
    implementations are prohibited.
14. **No long-lived compatibility path.** Once callers use a new phase product
    and parity is proven, delete the superseded representation and adapters.

## Current Production State

The following observations were revalidated before updating this roadmap.

### Completed Foundations

- `graph/definition_identity.brp`, `graph/definition_index.brp`, and
  `graph/indexed_graph.brp` own opaque module/declaration identities, the
  definition index, prepared modules, and the indexed graph.
- Definition reservation is deterministic and module-scoped.
- `modules/module_binding.brp`, `module_prelude.brp`,
  `module_selection.brp`, and `module_visibility.brp` own the mechanically
  separated module-binding responsibilities.
- The production bridge consumes indexed graph work items instead of rebuilding
  definition plans.

### Remaining Architectural Coupling

- Typechecking and Core import bindings use exhaustive qualified-module and
  selective-definition variants. The JSON bridge alone preserves its
  established nullable `original_name` wire shape as serialization, not
  semantic state.
- `CompilerModuleView` is opaque and solely owns imported modules, module
  aliases, selective names, ordered import bindings, and their exact indexes.
  Registration either returns a coherent new view or a typed conflict.
- `CompilerTypecheckState` still combines graph, module, environment, local
  inference, diagnostic, visibility, type-home, and resource-shape facts.
- Local top-level names, qualified aliases, and selective imports share the
  opaque `CompilerModuleView` namespace owner. Construction order cannot
  produce a contradictory successful view.
- `CompilerImportableModule` retains parsed callable/implementation provenance
  and a full parsed declaration list for later declaration phases. It no longer
  stores a second parsed type-declaration inventory.
- `headers/declaration_skeleton.brp`, `headers/type_header_dependencies.brp`,
  `headers/type_parameter_headers.brp`, and `headers/type_header_graph.brp` now
  build the immutable type-header phase products atomically. Named references,
  constructor parents, and bounded parameters use exact identity domains;
  prelude-provided nominal types use a closed identity that remains stable when
  a synthetic compiler request omits std source modules.
- `headers/type_header_install.brp` now installs builtin/resource-builtin,
  record/struct, union/enum, and transparent/opaque alias facts from opaque category-specific accepted
  headers. Definition-owned fields and payloads, generic parameters, layout,
  resource containment, constructor IDs, tags, and exact referenced
  declaration identities come from the graph; local or imported naming is
  applied only at the environment boundary. Production local, imported,
  traced, and CTFE paths consume these projections.
- Graph-backed production and multi-module tests install imported type facts
  only from an accepted `CompilerTypeHeaderGraph`. Isolated one-program checks
  retain local parsed registration in `headers/type_headers.brp`; that path
  cannot accept imported module bodies.
- `TraitRef` is currently `String`. Final callable and implementation headers
  therefore cannot yet carry stable trait identities.
- Imported unannotated globals still use `TYPE_VOID` as a temporary fallback.
  `Void` is a real language type and must not represent pending type inference.
- `InferContext` embeds the full `CompilerTypecheckState` and adds expected-type
  and control-flow flags. A body session can therefore reach graph mutation APIs
  that it should not possess.
- Typed AST definitions, expression inference, typed-tree traversal,
  finalization, and several validations remain concentrated in `infer.brp`.
- CTFE dependency preparation consumes graph-bound modules but still invokes
  full module typechecking and materializes every dependency body. Selective
  body materialization remains Phase 7.

### Performance Evidence

The validated CTFE workload in
`benchmarks/results/compiler_ctfe_typecheck_profile_2026-08-10.md` contains 24
modules and 32 functions per module. It materializes 768 dependency function
bodies while the fixture reaches only 24. Full dependency typechecking and body
inference dominate the profile.

This changes the priority after body independence is available: demand-driven
CTFE materialization is Phase 7, before solver and validation optimization.

The accepted `zonk_type` meta-free guard is a useful leaf optimization. A more
complex one-pass optional resolver was measured and rejected because it
regressed the targeted and representative workloads. Do not resume that
micro-optimization until the structural phases are complete and re-profiled.

## Target Ownership Boundaries

### Stage 04: Loaded Syntax

Owns source modules, canonical paths, parsed programs, and loader diagnostics.
It does not own semantic visibility, type headers, or callable identity.

### Stage 05: Shared Semantic Primitives

Owns stable semantic types and opaque identity types used by multiple
typechecking phases. Inference-only metavariables remain body-local and must not
become graph identities.

### Stage 06: Typechecking

Owns these areas:

```text
graph/          module and definition identity; indexed graph
modules/        bound module views and visibility
headers/        type, trait, callable, value, and implementation headers
body/           body contexts, sessions, inference, solving, validation
ctfe/           definition worklist and typed-body demand scheduling
assembly/       checked and codegen-ready graph construction
```

Directories are introduced only when the first authoritative responsibility
moves into them. Empty scaffolding and one-line forwarding modules are not
milestones.

### Stage 09 And Later

Core lowering receives `CompilerCodegenReadyGraph`, never parser declarations,
pending headers, inference sessions, unresolved metavariables, or rejected
bodies.

## Universal Checkpoint Workflow

Every numbered slice below follows this sequence. A slice is mergeable only
after completing all applicable steps.

### A. Characterize

1. Identify production entry points and all callers with `rg`.
2. Identify the current data owner and every duplicate representation.
3. List observable behavior: accepted programs, exact diagnostics, source
   spans, identity/order behavior, typed output, and Core output.
4. Add focused tests only for uncovered behavior or the invalid state being
   removed.
5. Record a benchmark baseline and checksum when the slice has a plausible
   performance effect.

### B. Mechanically Separate

1. Move cohesive implementation into the intended owner without changing its
   representation or algorithm.
2. Keep one production implementation. Temporary adapters may only translate
   at the boundary under migration.
3. Run focused tests after each movement.
4. Commit or otherwise checkpoint the mechanical move before representation
   changes when the move is non-trivial.

### C. Introduce The Phase Product

1. Define the minimum opaque type or precise union needed by downstream code.
2. Make construction validate all invariants available at that phase.
3. Expose semantic queries, not raw backing maps or parsed declarations.
4. Add construction, rejection, determinism, and opacity tests.
5. Make APIs accept the narrowest phase product they require.

### D. Cut Over And Delete

1. Convert one vertical production path to the new product.
2. Convert tests and benchmarks to the same production API.
3. Convert remaining callers.
4. Remove old fields, constructors, adapters, and parallel lookup paths.
5. Use `rg` to prove no stale production caller remains.

### E. Validate Parity

1. Run focused positive and negative tests, checking diagnostic text where
   relevant.
2. Run the relevant sanitizer test for ownership-sensitive changes.
3. Run active compiler gates and downstream smoke coverage.
4. Inspect typed output or generated Core/C when the boundary affects it.
5. Run `git diff --check` and inspect the diff for wrappers, duplicated facts,
   invalid optional states, and unrelated churn.

### F. Measure A Straightforward Optimization

1. Re-profile the phase after cutover.
2. Select one simple source of repeated work exposed by the new boundary.
3. Add counters that distinguish less work from a changed workload.
4. Compare interleaved baseline/candidate samples using the same bootstrap,
   fixture, C compiler, flags, and worker settings.
5. Retain the optimization only if the representative result is stable and the
   implementation remains simpler or clearly justified.
6. Record rejected experiments when they prevent repeated investigation.

## Progress Summary

### Phase 0: Observation Contract - Complete

Completed work established deterministic compiler benchmarks, checksums,
profiling entry points, and memory measurements. Existing durable results live
under `benchmarks/results/`.

### Phase 1: Graph Identity And Definition Indexing - Complete

Completed work introduced:

- opaque module and definition identities;
- an opaque conflict-rejecting definition index;
- deterministic module-scoped declaration reservation;
- an all-or-nothing indexed graph product;
- exact selected-module handling; and
- graph-owned work items consumed by the production bridge.

The completed implementation removed the prior definition-plan migration
records. Do not recreate them in later phases.

### Phase 2A: Mechanical Module Split - Complete

Module binding, prelude, selection, and visibility responsibilities now have
separate owners under `stage_06_typecheck/modules/`. This was a movement and
measurement checkpoint, not completion of the semantic module-view boundary.

### Phase 2B1: Precise Import Binding - Complete

Completed work introduced:

- `CompilerQualifiedModuleBinding` and
  `CompilerSelectiveDefinitionBinding` as the only typechecking binding
  shapes;
- kind-specific state queries and exhaustive CTFE, bridge, inference, and Core
  projection consumers;
- compile-time rejection coverage for the legacy record literal, a selective
  binding without a source name, and a qualified binding with a source name;
- ASan/UBSan coverage of state, import registration, declaration checking,
  CTFE globals, and bridge serialization; and
- an interleaved module-binding benchmark showing equivalent work and timing
  at parity, with no speedup claim.

The typechecker no longer branches on an optional field to discover binding
kind. The nullable JSON and Core shapes are explicit boundary projections, not
semantic typechecking state.

### Phase 2B2a: Opaque Imported Namespace View - Complete

Completed work introduced:

- an opaque `CompilerModuleView` with private ordered inventories and private
  exact indexes;
- conflict-returning smart operations for qualified aliases and selective
  names, including an explicit already-present alias result;
- one coherent clear operation that removes selective names from lookup and
  ordered binding projection together;
- exact module, alias, and selective-binding membership queries;
- migration of state, declaration, inference, CTFE, bridge, tests, and the
  module-binding benchmark away from public parallel collections; and
- compile-time opacity coverage plus focused ASan/UBSan and full codegen-audit
  validation.

The measured workload preserved checksum `1260800` and all semantic counters.
Its seven-sample candidate median was 57,568 microseconds versus the recorded
2B1 median of 110,256 microseconds. Because setup time also shifted and the 2B1
binary was not reconstructed for an interleaved comparison, retain the
architecture for correctness and exact lookup complexity but do not attribute
the full timing delta to this slice.

### Phase 2B2b: Unified Module Namespace - Complete

Completed work introduced:

- one opaque namespace owner for local definitions, qualified aliases, and
  selective imports;
- typed registration outcomes that reject conflicts in either construction
  order without returning a partially valid view;
- deterministic first-declaration-wins behavior for declaration pre-scan;
- one coherent reset operation for local and selective unqualified names;
- migration of state, declaration pre-scan, inference, and tests away from the
  separate `top_level_names` dictionary; and
- focused construction-order, opacity, sanitizer, name-lookup, and
  module-binding validation.

The name-lookup workload performed 3,276,800 exact lookups per sample at a
seven-process median of 21 nanoseconds per lookup. Registering 256 local and
256 imported names took a median 1,446 microseconds. The equivalent
module-binding workload retained checksum `1260800`; its 64.1 millisecond
median remains within the range of prior checkpoints. Those measurements do
not justify adding a bulk namespace builder.

## Phase 2: Bound Module Views

### Goal

Build one immutable semantic view per module from the indexed graph. Every
later header or body phase should ask that view what names and modules are
visible instead of replaying parsed imports or consulting parallel state lists.

### Input And Output

```text
Input:  CompilerIndexedGraph
Output: Result[CompilerBoundModuleGraph, List[CompilerModuleBindingError]]
```

`CompilerBoundModuleGraph` owns an ordered module inventory and exact lookup by
`CompilerModuleIdentity`. Each module has one opaque `CompilerModuleView`.

The initial import model should distinguish at least:

```text
CompilerQualifiedModuleBinding(
    local_name,
    target_module_id,
)

CompilerSelectiveDefinitionBinding(
    local_name,
    source_name,
    target_module_id,
    definition_id,
)
```

If traits or types need a distinct identity from `CompilerDefinitionId`, use
the appropriate stable identity in the selective variant. Do not add another
optional field to encode that distinction.

### Slice 2B1: Precise Import Binding - Complete

1. Qualified, selective, renamed, constructor, private, ambiguous, package,
   and stdlib behavior is covered by existing import and declaration suites.
2. Constructor arity and legacy-record rejection tests prove the two binding
   kinds cannot be confused or partially constructed.
3. Production typechecking and CTFE consumers use exhaustive union matches or
   kind-specific queries.
4. The JSON bridge preserves the existing diagnostic/tooling contract by an
   explicit projection.
5. The frontend projects into the current Core resolver shape at one named
   boundary; Core migration remains required before Phase 2 exits.
6. The old typechecking record and optional-kind branches are deleted.
7. The focused benchmark preserves its checksum and operation counts and
   measures at parity.

Merge condition: all production import-binding consumers use the union and no
optional field determines binding kind.

### Slice 2B2a: Opaque Imported Namespace View - Complete

1. `CompilerModuleView` privately owns ordered imported facts and exact
   indexes.
2. Smart registration rejects alias/selective conflicts without exposing a
   partial view, while an identical alias registration is explicitly
   idempotent.
3. State no longer exposes `module_aliases`, `imported_names`,
   `imported_names_by_local_name`, `imported_modules`, or `import_bindings`.
4. Name, type, UFCS, CTFE, bridge, and Core-boundary projection consumers use
   semantic view queries or deterministic ordered inventories.
5. Direct record construction is a compile error, and focused sanitizer suites
   cover managed view ownership and sharing.

Merge condition met: one opaque view is the sole owner of imported name and
module visibility facts.

### Slice 2B2b: Unified Module Namespace - Complete

1. Move `CompilerTopLevelNameKind` and the local-name index into the module-view
   owner, or into an opaque namespace component owned exclusively by the view.
2. Add a typed local-definition registration outcome that distinguishes an
   existing local declaration from conflicts with qualified and selective
   imports; never use booleans or optional coupled fields.
3. Preserve pre-scan's deterministic first-declaration behavior and exact
   import collision diagnostics.
4. Replace direct `top_level_names` reads and bulk dictionary installation in
   declaration pre-scan with view construction/query operations.
5. Make clearing a module namespace one coherent operation; no caller may clear
   local names while retaining stale selective bindings or vice versa unless a
   separately named imported-module-resolution view requires that distinction.
6. Add construction-order tests proving local-then-import and import-then-local
   operations cannot produce contradictory successful views.
7. Re-measure declaration pre-scan and module binding before adding another
   index; preserving a private linear ordered inventory is acceptable when no
   semantic lookup needs it.

Merge condition met: local definitions, module aliases, and selective imports share
one conflict-rejecting namespace owner, and `CompilerTypecheckState` has no
separate top-level-name dictionary.

### Slice 2B3: Bound Module Graph - Complete

- opaque bound module and graph representations retain the prepared scope,
  completed view, exact prelude-expanded program, and resolved visible/direct
  module sets;
- graph construction selects dependencies through the indexed graph before
  binding, distinguishes selection from binding errors, and never returns a
  partial graph;
- exact identity lookup verifies opaque identity equality after its keyed
  probe;
- binding failures are non-empty by construction; and
- normal and sanitizer tests cover order, lookup, invalid selection,
  deterministic rejection, ownership, opacity, and replay-free typechecking;
- recoverable user diagnostics are retained on a structurally valid bound
  module, while graph rejection is reserved for an incomplete/invalid view;
- ordinary, traced, standalone-source, and CTFE bridge paths consume bound
  modules, and canonical CTFE dependencies share the same bound graph;
- the narrower reusable-CTFE environment constructs a separately named bound
  product because it intentionally represents different visibility;
- `PreparedTypecheckModule` stores a bound module rather than parallel scope
  and view fields; and
- Core import resolution uses precise qualified and selective variants, with no
  optional field encoding import kind.

1. Construct views for the target and the request's selected/reachable module
   identities in deterministic order. Do not bind unrelated loaded modules;
   their diagnostics must remain isolated from the requested artifact.
2. Represent graph build as accepted or rejected; never expose a partially
   valid bound graph as success.
3. Preserve per-module recoverable diagnostics separately when tools need them.
4. Add exact identity lookup and ordered traversal APIs.
5. Convert ordinary typecheck and CTFE preparation to consume the same bound
   graph.
6. Remove parsed-import replay from downstream registration paths.
7. Ensure `CompilerImportableModule` no longer acts as a second semantic view.
   Retain parsed programs only in the earlier prepared/indexed product for later
   declaration-body access.
8. Replace `CoreResolveImportBinding` with precise Core variants, or remove the
   retained binding entirely if Core consumes it during graph construction.
   Phase 2 may not exit with optional data encoding import kind on either side
   of the frontend/Core boundary.

Merge condition met: downstream declaration phases receive bound modules and
cannot construct contradictory module visibility state.

### Slice 2D: Measured Simplification - Complete, No Optimization Retained

The completed bound graph preserved the module-binding checksum and semantic
operation counts. A follow-up timing run was contaminated by concurrent
compiler builds on the host and is not valid comparative evidence. Inspection
found no redundant production view rebuild or surface scan whose removal was
both local and clearly correct, so this checkpoint retains no speculative
optimization. Re-measure from a clean host before making a Phase 2 performance
claim.

1. Count path/name probes, dependency-closure visits, binding insertions, and
   view rebuilds in `benchmarks/compiler_module_binding_profile`.
2. Remove repeated module-surface scans made redundant by the view.
3. Add a secondary exact index only when counters show repeated linear lookup.
4. Preserve deterministic source order independently of lookup representation.

### Phase 2 Exit Criteria

- one opaque module view owns each module's semantic bindings;
- binding kind is a union variant, not optional-field convention;
- imports bind identities and visibility without installing semantic headers;
- no parallel list and dictionary can disagree about imported names;
- ordinary and CTFE paths consume the same bound graph; and
- module-binding diagnostics, ordering, checksums, and benchmark behavior remain
  stable.

## Phase 3: Declaration Skeletons And Type Headers - Complete

### Goal

Reserve stable identities for all semantic declaration categories, then resolve
every named type and constructor once for its defining module. Skeletons are
needed first because type declarations themselves can have trait-bounded type
parameters.

### Input And Output

```text
Input:  CompilerBoundModuleGraph
Output: CompilerDeclarationSkeletonGraph
        Result[CompilerTypeHeaderGraph, List[CompilerTypeHeaderError]]
```

The skeleton graph reserves typed identities, owner module, declaration
category, visibility, source span, diagnostic spelling, and exact source
provenance. Source provenance uses category-aligned variants or opaque locators,
so a function identity cannot point at a parsed type declaration. It is input to
later header/body construction, not a semantic signature. The type-header graph
distinguishes record, struct, union, enum, builtin, resource, transparent alias,
and opaque alias headers.

### Slice 3A: Extract Type Declaration Ownership - Complete

Completed work:

- moved known-type collection, constructor-ID reservation, local type
  registration, and imported type registration into
  `headers/type_headers.brp`;
- moved canonical annotation, qualified/imported alias resolution, and imported
  annotation resolution into `headers/type_resolution.brp`;
- retained one implementation for record, struct, union, enum, builtin,
  resource, transparent alias, and opaque alias registration;
- made constructor reservation return the exhaustive
  `CompilerConstructorIdPlan`, so imported and local unions cannot proceed with
  a partially present constructor-ID list;
- migrated declaration and implementation tests to the new owner; and
- preserved declaration diagnostics, definition IDs, type homes, resource
  containment, imported canonical names, and ordinary/CTFE bridge behavior.

1. Characterize local/imported type registration, recursive records/unions,
   aliases, opaque representations, constructor registration, containment,
   visibility, and duplicate diagnostics.
2. Move type declaration collection and source-to-header helpers from
   `typecheck_decl.brp` into `headers/type_headers.brp` without changing their
   current representations.
3. Keep parser declarations as construction input only.
4. Make ordinary and CTFE module paths call the extracted owner.
5. Run focused alias, opaque, resource, and recursive-type sanitizer tests.

### Slice 3B: Declaration Skeleton Graph - Complete

Completed work:

- introduced opaque category-specific identities for types, constructors,
  callables, traits, trait methods, globals, and implementations;
- built an atomic skeleton graph from the bound graph and definition index in
  deterministic target/dependency declaration order;
- retained category-aligned parsed provenance without nullable or cast-based
  source payloads;
- represented inherited trait-default callables separately from explicit
  implementation methods and recovered their reserved IDs by exact
  module/span identity;
- added a private name-bucket lookup accelerator whose candidates are always
  verified by exact typed identity;
- wired skeleton validation into standalone, ordinary, and traced production
  preparation paths; and
- covered ordering, repeated names, exact identity, visibility, source
  category, opacity, managed ownership, and default-method reservations in
  normal and sanitized tests.

1. Characterize identity reservation for types, constructors, functions,
   overloads, foreign functions, traits, trait methods, default methods,
   globals, and implementations.
2. Build `CompilerDeclarationSkeletonGraph` from the bound module graph and the
   existing definition index in deterministic order.
3. Introduce distinct opaque identity domains where they prevent category
   confusion: `CompilerTypeId`, `CompilerConstructorId`,
   `CompilerCallableId`, `CompilerTraitId`, `CompilerTraitMethodId`,
   `CompilerGlobalId`, and `CompilerImplId` as needed.
4. Reuse `CompilerDefinitionId` as backing storage only behind checked typed
   constructors. A raw ID from one category must not construct another.
5. Store owner module, visibility, source span, declaration category, and
   diagnostic spelling.
6. Associate the identity with a precise `CompilerDeclarationSource` variant or
   opaque locator whose payload category matches the skeleton category. Do not
   use one record containing a category enum plus optional parsed declarations.
7. Expose source lookup only to header/body construction; semantic lookup uses
   resolved header graphs.
8. Reserve every named type before resolving type bodies, supporting legal
   recursive references without placeholder semantic types.
9. Reserve every trait before resolving type-parameter bounds in type headers.
10. Reject category conflicts, duplicate skeletons, source-category mismatches,
   and identity reuse during
   graph construction.
11. Add exact identity, opacity, conflict, source-category, and deterministic
    inventory tests.

### Slice 3C: Resolve Headers - Complete

Completed work:

- added an opaque definition-local alias dependency graph with structural
  traversal of nested type expressions;
- modeled traversal state explicitly as unvisited, visiting, or complete;
- reject deterministic local transparent and opaque alias cycles before
  environment installation, while leaving record/union recursion legal;
- added a graph-wide dependency graph whose nodes and edges use opaque
  `CompilerTypeId` values rather than source spellings;
- resolve qualified and selective imported alias edges through immutable module
  views and the bound module graph, with exact identity verification after
  indexed lookup;
- refine a validated dependency graph to the opaque
  `CompilerAcyclicTypeAliasDependencyGraph` product so later header
  construction cannot receive an unchecked cyclic graph;
- resolve every type-declaration parameter bound to an exact
  `CompilerTraitId`, including selectively imported traits, and reject unknown
  bounds before CTFE or body inference;
- require the opaque `CompilerResolvedTypeParameterGraph` to be constructed
  from an already-acyclic alias graph, so unresolved bounds and unchecked alias
  cycles cannot reach type-header construction;
- retain the strongest resolved-parameter product in
  `PreparedTypecheckContext` and expose production trace events for both
  completed boundaries;
- resolve record fields, union payloads, alias targets, function types,
  dimensions, tuples, and arrays into a closed `CompilerResolvedTypeShape`;
- preserve exact constructor-to-parent `CompilerTypeId` relationships instead
  of recovering ownership from constructor names;
- distinguish compiler intrinsics, declaration identities, owner-scoped type
  parameters, and prelude nominal identities in the resolved shape;
- keep prelude identity stable when std source is loaded or omitted while
  preserving legal local shadowing;
- encode record/struct, union/enum, alias opacity, builtin/resource cleanup,
  and transitive resource-containment facts in category-specific headers;
- construct `CompilerTypeHeaderGraph` atomically, retain it in production
  preparation, and expose exact-ID lookup plus deterministic inventory; and
- added normal, sanitizer, production-diagnostic, exact-resolution, trace, and
  opacity coverage.

This slice is complete. Slice 3D subsequently made the accepted graph the sole
installer of imported environment type facts and deleted parsed replay.

1. Resolve type-parameter bounds against `CompilerTraitId` skeletons. Do not
   store final resolved bounds as source strings.
2. Build a dependency graph for aliases and other type-level dependencies.
3. Define legal recursive strongly connected components explicitly. Reject
   illegal alias cycles with stable diagnostics.
4. Resolve field, variant, representation, and constructor parameter types
   against skeleton identities.
5. Preserve the distinction between a private type appearing in an exported
   shape and a private name becoming importable.
6. Compute resource/layout/containment facts once per accepted header when
   those facts are definition-owned.
7. Construct `CompilerTypeHeaderGraph` only after all required identities and
   resolved headers agree.

### Slice 3D: Production Cutover And Deletion - Complete

Completed work:

- builtin/resource headers expose opaque category-specific accepted values;
- local inventory includes private declarations while imported inventory is
  filtered by skeleton visibility, not source-shape heuristics;
- cleanup policy, type parameters, resource capability, canonical imported
  names, aliases, and type homes install from accepted headers;
- ordinary, traced, and CTFE graph compilation all use the same header-backed
  path; and
- record/struct headers expose a separate opaque accepted projection, and their
  resolved field shapes are converted exhaustively to transitional
  `SemanticType` values only at installation;
- declaration IDs determine owner qualification, so same-spelling local,
  imported, intrinsic, prelude, and type-parameter references cannot be
  confused by the adapter;
- transparent aliases are expanded from accepted graph headers with
  substitutions keyed by exact `CompilerTypeParameterId`; installation order
  is no longer part of record-field correctness, while opaque aliases remain
  nominal;
- references that resolve to a declaration retain their exact
  `CompilerTypeId`, including declarations whose names also belong to the
  implicit prelude; `CompilerPreludeTypeShape` is reserved for the implicit
  fallback when no declaration was resolved, so a selective `fs.IOError`
  import cannot degrade to an unqualified nominal type;
- implicit prelude identities retain their stable closed representation, while
  an exact graph query identifies the owner-provider case that requires
  canonical imported naming to agree with constructor parents;
- record layout and transitive resource containment install directly from the
  accepted header without parsed validation or containment rescans;
- union/enum headers retain each constructor identity, payload, and tag as one
  accepted variant until the final transitional environment call, preventing
  independently reordered constructor-ID and variant lists;
- tagged-union versus fieldless-enum layout, recursive generic payloads,
  transparent-alias expansion, canonical imported constructor parents, and
  transitive resource containment install from accepted headers; and
- local parsed type-declaration registration is isolated to one-program checks
  that cannot accept imported module bodies;
- transparent and opaque aliases have a separate accepted projection that
  couples layout with its exact resolved target;
- generic alias targets are converted from exact identities at the Env
  boundary, with transparent dependencies expanded independently of source
  installation order;
- only opaque aliases receive nominal type homes, while imported aliases of
  either layout receive canonical importer bindings; and
- alias-only parsed selection and graph-backed parsed replay have been deleted.

1. Replace importer-side parsed type registration with header lookup by ID.
2. Convert pattern, constructor, alias, resource, and type-home consumers.
3. Remove imported parsed type declaration replay.
4. Remove duplicate known-type, resource-type, and type-home state where the
   graph now owns the fact.
5. Confirm Core receives the same resolved type shapes and identities.

### Slice 3E: Measured Optimization

1. Add a type-heavy fixture with nested types, aliases, recursive declarations,
   private types, and high import fan-out.
2. Count source-type resolutions, containment scans, header installations, and
   importer-side type work.
3. Eliminate repeated imported-type resolution and containment scans.
4. Defer type interning until the stable header graph proves it is needed.

This slice is complete. It retained the keyed known-type index, exact-ID header
lookup table, and keyed module projection inventories described in the
Immediate Execution Plan below.

### Slice 3F: Semantic Namespace Uniqueness - Complete

Completed work:

- added explicit semantic namespace keys distinct from span-bearing exact
  declaration identities;
- reject duplicate type names, duplicate trait names, and duplicate
  constructor names within one parent atomically during skeleton construction;
- preserve legal callable overloads and same-named constructors owned by
  different unions; and
- cover exact production diagnostics and the complete declaration-category
  inventory.

The closure audit proved that exact identity equality is not a semantic
duplicate check. Declaration identities include source spans, so two
same-named declarations at different locations receive distinct IDs and both
enter the skeleton graph. Production currently accepts duplicate type
declarations and duplicate variants within one union.

1. Add failing production-graph tests for two records with one name, a
   record/union name collision, duplicate traits, and duplicate constructors
   within one union. Assert exact diagnostics.
2. Characterize every legal repeated-name case before choosing keys. Function
   overloads and same-named constructors belonging to different unions are
   legal and must remain representable.
3. Introduce explicit private semantic namespace keys. At minimum, type
   declarations conflict by exact module plus source name, traits use their
   characterized namespace, and constructors conflict by exact parent type ID
   plus constructor name.
4. Keep declaration identity separate from namespace identity. Source span and
   runtime definition ID remain part of exact declaration identity but cannot
   decide whether a semantic name is duplicated.
5. Make skeleton construction reject the complete graph atomically on a
   conflict; indexed lookup must never choose the first of duplicate semantic
   declarations.
6. Expand the skeleton inventory fixture to exercise builtin types, aliases,
   and foreign functions in addition to its existing categories.

Merge condition: no non-overloadable semantic namespace can contain two
skeletons, while legal overload and cross-parent constructor cases remain
covered.

### Slice 3G: Explicit Value-Layout Recursion - Complete

Completed work:

- added an exhaustive inline-storage dependency classification over accepted
  resolved shapes;
- reject direct, mutual, alias-mediated, stack `Option`, stack `Result`, and
  stack `TaskResult` layout cycles with deterministic cycle paths before an
  opaque header graph can be constructed;
- classify every current resolved shape and accepted header layout
  exhaustively, so a future representation cannot silently default to an
  indirect edge;
- pre-index inline-layout edges and use an iterative depth-first traversal,
  avoiding full node scans and source-depth recursion;
- preserve legal recursion across heap records and unions while retaining the
  existing rule that unmanaged structs cannot own managed fields; and
- cover rejection through the production bridge and compile legal heap
  recursion through the generated-C warning audit.

Alias cycles already refine to `CompilerAcyclicTypeAliasDependencyGraph`, and
heap record/union recursion is legal. The closure audit found that production
also accepts direct and mutual recursion composed entirely of value structs.
Those layouts require infinite inline storage and must not reach Core.

1. Add failing production-graph tests for direct value-struct recursion,
   mutual value-struct recursion, transparent aliases, and specialized
   stack-value wrappers.
2. Add positive tests for recursion that crosses a heap record or heap union.
   Do not restore the stale rule that rejected every recursive record.
3. Define an explicit storage-edge classification for every resolved shape.
   The classification must cover specialized builtin layouts such as stack
   `Result`; do not infer indirection from type names.
4. Build an exact-ID value-layout dependency graph after all type headers are
   resolved but before `CompilerTypeHeaderGraph` is constructed.
5. Represent validation as a distinct acyclic layout product or as an atomic
   typed header-construction error containing a deterministic cycle path.
6. Keep alias-cycle and value-layout-cycle diagnostics distinct: one is an
   invalid type equation, the other is an infinitely sized representation.

Merge condition: a completed type-header graph cannot contain an inline storage
cycle, while legal heap recursion remains accepted and codegen-tested.

### Slice 3H: Delete Parsed Imported-Type Replay - Complete

Completed work:

- migrated multi-module declaration tests to construct the same indexed,
  bound, skeleton, alias, parameter, and accepted-header products as
  production;
- made graph-capable typecheck APIs require `CompilerTypeHeaderGraph`
  directly;
- introduced opaque `CompilerAcceptedTypecheckModule`; its ordinary constructor
  admits canonical graph bindings by module identity, while a separately named CTFE
  artifact constructor builds the alternate binding internally from the
  dependency-only inventory and validates its reserved state, so target-aware
  bindings cannot enter that path; the opaque value retains this import-scope
  distinction through body materialization, so the exception cannot silently
  become the ordinary API;
- introduced opaque `CompilerImportableModuleGraph` as the single body-bearing
  projection of an indexed graph, including both dependencies and target;
- introduced opaque `CompilerAcceptedTypecheckGraph` as the validated join of
  definition-only type headers and the compatible importable-module graph, so
  neither product has to absorb the other's ownership;
- deleted parsed imported-type registration, containment, type-home, and
  annotation replay helpers;
- removed the parsed type-declaration inventory from
  `CompilerImportableModule`; and
- retained parsed registration only for local declarations in isolated
  one-program tests, which cannot represent imported module installation.

Production ordinary, CTFE, traced, and standalone bridge paths build one
`CompilerAcceptedTypecheckGraph` and project every imported type fact from its
definition-only headers. No parsed imported-type branch remains. Local parsed
registration is retained only for isolated one-program checks that cannot
represent imported module semantics.

1. Migrate multi-module fallback tests to a bound graph plus accepted type
   headers. Preserve their import, diagnostic, and typed-program assertions.
2. Keep local parsed declaration registration only for isolated one-program
   unit tests that cannot own imported module semantics. Name that boundary
   explicitly.
3. Delete `CompilerTypeFactInstallation` and its parsed imported-declaration
   variant; graph-capable functions accept `CompilerTypeHeaderGraph` directly.
4. Delete `typecheck_register_imported_type_decls` and related parsed imported
   containment/type-home helpers when their final callers are gone.
5. Remove parsed type-declaration fields from `CompilerImportableModule` if no
   remaining surface, signature, or tooling consumer needs them.
6. Add a source-ownership regression or structural quality check proving that
   APIs accepting imported module bodies cannot install type facts without an
   accepted header graph.

Merge condition: imported type facts have one callable implementation and are
always projected from accepted headers.

### Phase 3 Exit Criteria

- every named type and constructor has one definition-owned semantic header;
- every semantic declaration category has a typed skeleton identity before
  header resolution;
- bounded type declarations refer to stable trait identities;
- importers bind stable identities instead of replaying parsed type declarations;
- legal recursion and illegal cycles are explicit construction outcomes;
- no type-home or containment fact has contradictory owners; and
- the type-header graph is immutable input to later declaration phases.

## Phase 4: Declaration Identities And Headers

### Goal

Resolve trait headers, callable signatures, declared values, and
implementations once per definition using the skeleton identities established
in Phase 3.

### Input And Outputs

```text
Input:  CompilerDeclarationSkeletonGraph + CompilerTypeHeaderGraph
Output: CompilerDeclarationHeaderGraph
```

The header graph contains accepted type-resolved declaration headers plus
explicit pending global initializer entries.

### Slice 4A: Trait Headers

1. Characterize traits, supertraits, methods, defaults, visibility, bounds, and
   duplicate diagnostics.
2. Replace graph-boundary `TraitRef = String` with stable `CompilerTraitId`
   references after name resolution. Source spelling remains diagnostic data.
3. Resolve supertraits and detect cycles using trait IDs.
4. Use the stable method identities reserved in Phase 3 and resolve method
   signature headers.
5. Record required/default method category explicitly.
6. Build deterministic method lookup by trait and method identity.
7. Convert trait lookup consumers before deleting stringly semantic references.

Merge condition: a resolved bound or implementation cannot name a trait solely
by source string.

### Slice 4B: Callable And Value Headers

1. Extract signature registration and resolution into
   `headers/callable_headers.brp`.
2. Resolve parameter, result, generic bound, purity, resource, dimension, and
   callback metadata against type and trait identities.
3. Distinguish functions, overload alternatives, foreign functions, trait
   methods, default methods, and constructor callables with variants or typed
   headers where their invariants differ.
4. Resolve annotated global value headers directly.
5. Represent unannotated globals as `CompilerPendingGlobalInitializer`, never
   as `TYPE_VOID`, `None`, or an incomplete callable/value header.
6. Preserve overload order and exact ambiguity diagnostics.

### Slice 4C: Implementation Headers And Index

1. Resolve each implementation to `CompilerImplId`, `CompilerTraitId`, owner
   module, generic bounds, receiver type head, and method identities.
2. Validate orphan, overlap, required-method, and default-method rules at the
   earliest phase with sufficient facts.
3. Build a conservative candidate-superset index keyed by trait identity and
   receiver head category.
4. Keep exact matching authoritative; the index may reduce candidates but must
   never exclude a legal implementation.
5. Convert UFCS and trait call resolution to stable identities.
6. Delete importer-side implementation reconstruction and private parallel
   implementation lists once all consumers use the graph.

### Slice 4D: Production Cutover And Measurement

1. Convert name lookup, overload, callback, trait, UFCS, and implementation
   consumers to declaration-header graph queries.
2. Remove signature and trait installation into each importer environment.
3. Add import-heavy and trait-heavy benchmarks.
4. Count signature resolutions, imported installations, trait candidate visits,
   exact matches, and bound checks.
5. Optimize only repeated definition-owned work or measured candidate scans.

### Phase 4 Exit Criteria

- trait identities exist before final callable bounds are resolved;
- all callable and implementation headers are definition-owned;
- pending globals are a distinct variant;
- importers bind declaration IDs without reconstructing signatures;
- trait candidate indexes are conservative and exact matching remains the
  correctness boundary; and
- no later phase depends on string-only resolved trait identity.

## Phase 5: Global Initializers And Header Completion

### Goal

Infer each unannotated global initializer once and produce a completed immutable
header graph for ordinary body checking.

### Input And Outputs

```text
Input:  CompilerDeclarationHeaderGraph
Output: CompilerHeaderCompletionOutcome

CompilerHeaderCompletionOutcome =
    CompilerHeaderGraphAccepted(CompilerHeaderGraph)
    CompilerHeaderGraphRejected(CompilerRecoverableHeaderGraph, diagnostics)
```

`CompilerHeaderGraph` contains no pending value type. Recovery artifacts may
retain explicit pending/rejected entries for diagnostics and tooling.

### Slice 5A: Initializer Dependency Plan

1. Characterize annotated and inferred globals, source-order references,
   cross-module dependencies, cycles, mutable restrictions, initializer calls,
   and CTFE-visible globals.
2. Build initializer dependencies by stable global/definition identity.
3. Distinguish annotated headers, pending inferred initializers, accepted
   inferred headers, and rejected initializers explicitly.
4. Define legal annotated cycles and reject unresolved inferred cycles with a
   deterministic diagnostic.
5. Never use `TYPE_VOID` to break or defer an initializer dependency.

### Slice 5B: Restricted Initializer Context

1. Introduce `CompilerInitializerCheckContext` containing only the type graph,
   declaration headers available at that point, module view, current global
   identity, and initializer dependency facts.
2. Do not require a completed `CompilerHeaderGraph`; that graph is the output of
   this phase.
3. Do not expose ordinary body graph mutation, Core counters, or unrelated
   module registration APIs.
4. Give each initializer fresh initializer-local inference state. Phase 6 may
   share the underlying body-local session machinery after its invariants are
   explicit, but the initializer context remains a distinct capability.
5. Record inferred type, typed initializer, dependencies, and diagnostics in an
   explicit outcome.

### Slice 5C: Complete Headers Once

1. Process dependency components in deterministic order.
2. Infer each pending initializer exactly once.
3. Validate declared annotations against inferred initializer types.
4. Install accepted inferred headers in a completion builder private to this
   phase.
5. Construct `CompilerHeaderGraph` only when every required header is complete.
6. Preserve a recoverable rejected product for tools without making it
   codegen-ready.

### Slice 5D: Cutover, Delete, And Measure

1. Convert ordinary bodies, importers, and CTFE scheduling to completed or
   explicitly rejected header outcomes.
2. Delete `TYPE_VOID` pending-global fallbacks and placeholder replacement.
3. Delete importer environment rebuilding caused by late inferred globals.
4. Add a globals benchmark with source-order, cross-module, annotated, inferred,
   and cyclic cases.
5. Count initializer inference runs, dependency probes, header updates, and
   imported installations.

### Phase 5 Exit Criteria

- every usable global header has a real type;
- every pending or rejected initializer is explicit and cannot reach ordinary
  body checking as accepted;
- each initializer is inferred once per graph;
- dependency and cycle behavior is deterministic; and
- CTFE receives typed initializers without re-running type inference.

## Phase 6: Independent Body Checking

### Goal

Make every function, method, and required initializer body independently
checkable against immutable graph facts.

### Input And Output

```text
Input:  CompilerBodyCheckContext + fresh CompilerInferSession
Output: CompilerBodyCheckOutcome

CompilerBodyCheckOutcome =
    CompilerBodyCheckAccepted(CompilerCheckedBodyArtifact)
    CompilerBodyCheckRejected(CompilerRecoveredBodyArtifact, diagnostics)
```

The accepted artifact is a stable facade over the existing complete body-check
contract. At Phase 6 it is constructed only after all checks currently required
for an accepted typed body have run. Phases 8 and 9 replace that construction
internally with explicit inferred, solved, and validated products. They do not
weaken the facade or require CTFE scheduling to understand partial body states.

`CompilerBodyCheckContext` contains the immutable completed header graph, one
module view, the body header/identity, and read-only compiler policy.
`CompilerInferSession` owns lexical scopes, metavariables, substitutions,
expected-type state, local/resource IDs, body-local diagnostics, and control
context.

### Slice 6A: Extract Typed AST Ownership

1. Inventory typed AST definitions and every import of them.
2. Move typed expression/declaration model types from `infer.brp` into a lower
   `body/typed_ast.brp` owner without changing representation.
3. Move pure typed-node accessors only when they are semantic model operations.
4. Keep inference-specific constructors in inference.
5. Avoid forwarding wrappers whose only purpose is preserving an old import.

### Slice 6B: Extract Typed Traversal And Finalization Utilities

1. Inventory every recursive typed-tree traversal and the facts it computes.
2. Move generic, acyclic traversal helpers into `body/typed_ast_walk.brp`.
3. Keep rule-specific traversal with its rule until Phase 9.
4. Preserve node order, source spans, and metadata exactly.
5. Do not combine unrelated facts into an untyped Boolean bag.

### Slice 6C: Introduce Body Check Context

1. List every graph/module/header read made during one body check.
2. Define the minimum immutable context that supports those reads.
3. Add query methods on header and module views instead of copying their maps
   into a body environment.
4. Adapt the existing inference kernel to accept the context while retaining
   the current broad session internally.
5. Convert one body category at a time: ordinary functions, methods, defaults,
   and any remaining initializer body.

### Slice 6D: Isolate The Inference Session

1. Classify every `CompilerTypecheckState`, `Context`, `Env`, and `InferContext`
   field as graph-wide immutable, module immutable, body local, expression
   contextual, lowering-only, or obsolete.
2. Move body-local lexical scopes, metas, substitutions, local IDs, resource
   scopes, expected return state, loop/debug state, and local diagnostics into
   `CompilerInferSession` or a precise nested context.
3. Replace control Booleans with enums/variants when combinations are invalid
   or have distinct behavior.
4. Remove graph mutation capabilities from body APIs.
5. Keep allocation/counter state needed only after typechecking out of the body
   session.
6. Delete migrated fields from broad state after the final consumer moves.

### Slice 6E: Define The Complete Body-Check Facade

1. Introduce opaque `CompilerCheckedBodyArtifact` and
   `CompilerRecoveredBodyArtifact` values around the current complete body
   result and recovery result.
2. Introduce `CompilerBodyCheckOutcome` with accepted and rejected variants.
3. Construct the accepted artifact only after the current inference,
   finalization, and semantic checks have accepted the body.
4. Do not represent a missing or rejected typed body as a normal body with
   `TYPE_VOID`, empty fields, or a success Boolean.
5. Ensure body-local IDs cannot be confused with graph definition IDs.
6. Make CTFE and ordinary module materialization call this one facade.
7. Reserve `CompilerInferredBody` and `CompilerSolvedBody` for the internal
   products introduced in Phase 8; do not expose partial results through the
   facade.

### Slice 6F: Prove Independence

1. Check the same set of bodies in source order, reverse order, and a fixed
   shuffled order.
2. Compare each body's typed result, stable call identities, diagnostics, and
   module-level sorted diagnostic aggregate.
3. Verify body checking does not change the header graph or another body's
   session.
4. Run focused sanitizer coverage for closures, resources, concurrency,
   generics, and nested typed metadata.

### Slice 6G: Carefully Decompose The Inference Kernel

1. Build an import/call graph for candidate inference clusters.
2. Extract genuinely acyclic services first: literals, local binding helpers,
   call candidate lookup, pattern utilities, resource facts, or tensor helpers
   only where the dependency direction is clear.
3. Keep mutually recursive expression inference and dispatch together when a
   split would require cyclic wrappers or callback indirection.
4. Delete old helpers after each vertical cutover.
5. Judge success by ownership clarity, testability, and reduced dependency
   surface, not by number of files.

### Slice 6H: Measure

1. Add a body benchmark covering many small independent bodies plus generic,
   call-heavy, resource-heavy, and large nested variants.
2. Count body context construction, graph/environment copies, local symbol
   operations, meta operations, and typed-node visits.
3. Remove graph rebuilding and general-state copying at body entry.
4. Retain read-only graph references instead of installing semantic symbols per
   body.

### Phase 6 Exit Criteria

- each body is checked from one immutable context and one fresh session;
- checking order does not affect semantic identity, typed output, or diagnostics;
- body code cannot mutate graph-wide semantic facts;
- CTFE and ordinary materialization use one complete body-check facade;
- the broad `InferContext` no longer embeds all typecheck state; and
- inference decomposition has no wrapper-only modules or artificial cycles.

## Phase 7: Demand-Driven CTFE Body Materialization

### Goal

Typecheck only bodies reachable from CTFE roots, reuse those accepted body
artifacts for ordinary output, and never guess reachability from source names.

This phase is intentionally before solver and validation restructuring because
the current profile shows eager CTFE dependency-body materialization is the
largest known typechecking cost.

### Input And Output

```text
Input:  CompilerHeaderGraph + complete body-check facade + CTFE root IDs
Output: CompilerCtfeBodySet + deterministic per-definition outcomes
```

### Slice 7A: Exact Worklist Model

1. Characterize CTFE roots, direct calls, recursive calls, cross-module calls,
   function values, higher-order calls, overloads, trait dispatch, failures,
   and dependency cycles.
2. Introduce `CompilerBodyWorklist` keyed by stable definition/callable IDs.
3. Represent work states precisely, for example unseen, queued, checking,
   accepted, and rejected. Prevent duplicate queue entries by construction.
4. Use deterministic root and discovered-dependency ordering.
5. Keep body result storage separate from work state if that avoids invalid
   optional combinations.

### Slice 7B: Discover Dependencies From Typed Metadata

1. Start from globals/expressions explicitly selected for CTFE.
2. Check a required body through the Phase 6 facade, receiving a complete
   accepted or rejected body outcome rather than a raw inferred body.
3. Traverse resolved typed call and function-reference metadata to discover the
   exact target IDs.
4. Enqueue newly discovered IDs once.
5. Handle recursion through visited IDs, not depth limits or source-name tests.
6. For higher-order or dynamic trait cases, add explicit typed metadata or an
   explicit conservative candidate set. Never infer dependencies from parsed
   names, callee text, or naming conventions.

### Slice 7C: Reuse Accepted Bodies

1. Store each accepted `CompilerCheckedBodyArtifact` under its definition
   identity.
2. Make ordinary selected-module assembly request the same artifact before
   invoking body checking.
3. Preserve module/source output order independently of worklist order.
4. Aggregate diagnostics deterministically by stable module/definition order.
5. Prove each required body is checked at most once per graph.

### Slice 7D: Cut Over And Delete

1. Move CTFE dependency scheduling from `typecheck_bridge.brp` into `ctfe/`.
2. Convert `ctfe_imported_program_from_prepared` and
   `prepare_ctfe_dependencies` callers to the worklist API.
3. Remove full dependency-module body materialization from CTFE preparation.
4. Keep bridge code responsible only for request orchestration and result
   transport.
5. Delete old CTFE typed-program reconstruction once no caller remains.

### Slice 7E: Validate The Known Workload

1. Run `benchmarks/compiler_ctfe_typecheck_profile` with the same 24 by 32
   fixture and checksum.
2. Record total dependency declarations, queued bodies, accepted bodies,
   duplicate requests, header lookups, and CTFE evaluations.
3. Verify the representative case checks the 24 reachable functions rather
   than all 768 dependency functions, subject only to explicitly documented
   conservative dynamic-call candidates.
4. Compare wall time, peak memory, diagnostics, typed output, and Core output.
5. Add a low-CTFE workload to catch fixed work or lookup regressions.

### Phase 7 Exit Criteria

- CTFE reachability is definition-driven and deterministic;
- no parsed-name heuristic affects correctness;
- every required body is checked at most once per graph;
- accepted CTFE bodies are reused by ordinary output;
- failed or cyclic work has explicit outcomes; and
- the known eager-materialization profile is substantially reduced.

## Phase 8: Constraint Solving And Type Finalization

### Goal

Separate inference from the guarantee that no body-local inference state can
escape into a completed typed body.

### Input And Output

```text
Internal input:  CompilerInferredBody
Internal output: Result[CompilerSolvedBody, CompilerBodySolveFailure]
Public facade:   CompilerBodyCheckOutcome
```

`CompilerSolvedBody` is opaque and constructible only after a complete
meta-freedom invariant check.

### Slice 8A: Extract Solver Ownership

1. Characterize the current boundary between expression inference,
   finalization, and validation, plus fresh metas, meta origins, binding,
   occurs checks, unification,
   overload deferral, dimension solving, unresolved diagnostics, resolution,
   and zonking.
2. Introduce opaque `CompilerInferredBody` around the exact typed shape and
   body-local solver state emitted by inference. It is internal to body
   checking and cannot satisfy the public accepted-body facade.
3. Move solver operations into `body/solver/` without changing algorithms.
4. Keep semantic stable types separate in ownership from inference tables even
   if they still share a transitional union representation.
5. Make all solver inputs body-local.

### Slice 8B: Precise Meta Storage

1. Introduce opaque `CompilerMetaId`; raw IDs from other domains must not be
   accepted.
2. Replace list-based meta bindings with a dense body-local table or another
   exact indexed representation.
3. Preserve origin information needed for diagnostics.
4. Add occurs-check and resolution-chain invariants.
5. Add path compression or union-find only after the dense representation is
   correct and measurement shows further need.

### Slice 8C: Solved Body Boundary

1. Resolve all semantic types, value slots, call metadata, pattern metadata,
   dimensions, proofs, and nested typed nodes.
2. Perform one final recursive invariant check for remaining body-local metas.
3. Construct `CompilerSolvedBody` only on success.
4. Preserve a separate failure/recovery artifact for diagnostics.
5. Make validators accept only solved bodies.

### Slice 8D: Measure

1. Use generic, overload, callback, recursive, range, and dimension-heavy
   bodies with controlled meta counts.
2. Count binding probes, updates, occurs checks, resolution-chain visits, and
   whole-body finalization visits.
3. Retain the current meta-free zonk guard.
4. Do not revive the rejected one-pass optional resolver without new profile
   evidence.
5. Remove repeated whole-body zonking only where the solved-body invariant
   remains mechanically verified.

### Phase 8 Exit Criteria

- all metavariable state is body-local and exactly indexed;
- downstream APIs cannot accept an inferred body where a solved body is
  required;
- no meta can remain in any nested solved-body fact;
- the complete body-check facade still returns only accepted or rejected body
  artifacts;
- diagnostics retain useful source origins; and
- generic, overload, refinement, and dimension behavior remains unchanged.

## Phase 9: Semantic Body Validation

### Goal

Create explicit accepted/rejected body outcomes while preserving each safety
check at the earliest phase with enough information.

### Input And Output

```text
Input:  CompilerSolvedBody
Output: CompilerBodyValidationOutcome

CompilerBodyValidationOutcome =
    CompilerBodyAccepted(CompilerValidatedBody)
    CompilerBodyRejected(CompilerRejectedBody, diagnostics)
```

### Rule Placement

Keep these checks during binding or inference when delaying them would lose
lexical facts or produce worse recovery:

- local binding and assignment legality;
- expected-type and constraint generation;
- lexical resource availability and derivation;
- resource use inside `with` scopes;
- closure and concurrent capture restrictions;
- pattern bindings and pattern/type constraints; and
- control-context rules such as loop-only operations.

Move or consolidate these checks after solving when they depend on final types
or currently rescan the typed body:

- declared purity and callback-purity validation;
- debug-only call restrictions where stable call facts suffice;
- module assignment restrictions where stable binding facts suffice;
- match exhaustiveness after typed pattern resolution;
- tail-recursion validation;
- final resource non-escape confirmation; and
- final typed-body invariants.

This table is a correctness boundary, not merely a preferred file layout.

### Slice 9A: Inventory And Fact Types

1. Inventory every semantic check, current execution point, required facts,
   traversal count, diagnostic order, and recovery behavior.
2. Define structured fact types for calls/effects, assignments, patterns,
   tail-call positions, resource scopes/derivations, and captures only where
   they eliminate duplicate traversal or string identity.
3. Use stable local/resource/call IDs instead of owner-name strings.
4. Do not create one miscellaneous flags record.

### Slice 9B: Mechanical Rule Extraction

1. Move one rule and its tests at a time under `body/validation/`.
2. Preserve its original execution point during movement.
3. Keep exact source spans and diagnostic ordering.
4. Delete old traversal only after all callers use the new owner.
5. Commit each rule family independently when practical.

### Slice 9C: Validated Body Outcome

1. Make post-solve validators consume `CompilerSolvedBody`.
2. Aggregate rule outcomes deterministically.
3. Construct `CompilerValidatedBody` only when every required rule accepts.
4. Construct `CompilerCheckedBodyArtifact` from the validated body and preserve
   the Phase 6 facade's accepted contract.
5. Retain `CompilerRejectedBody` only for diagnostics/tools and adapt it to the
   facade's recovered artifact.
6. Prove CTFE, ordinary materialization, and Core-facing APIs cannot accept the
   rejected variant.

### Slice 9D: Consolidate Measured Traversals

1. Benchmark large nested bodies with calls, lambdas, matches, resources,
   concurrency, and control flow.
2. Count typed-node visits by rule and total validation traversals.
3. Collect compatible facts during one traversal when ownership remains clear.
4. Keep separate traversals when combination would couple unrelated rules or
   obscure diagnostic order.
5. Document every retained whole-body traversal and its reason.

### Phase 9 Exit Criteria

- accepted and rejected bodies are distinct types;
- Core cannot receive rejected bodies;
- lexical safety checks remain at the earliest sound phase;
- post-solve rules consume stable identities and final types;
- diagnostic order and text remain stable; and
- no redundant typed-tree scan remains without measured justification.

## Phase 10: Checked Graph And Codegen-Ready Graph

### Goal

Assemble deterministic compiler/tool artifacts without conflating recoverable
typechecking output with valid Core input.

### Inputs And Outputs

```text
Inputs: CompilerHeaderCompletionOutcome
        per-definition body validation outcomes
        CTFE outcomes

Outputs: CompilerCheckedGraph
         Option[CompilerCodegenReadyGraph]
```

`CompilerCheckedGraph` may contain accepted and rejected artifacts for
diagnostics, inventories, and tooling. `CompilerCodegenReadyGraph` exists only
when every definition required by the selected compilation target has an
accepted header, accepted validated body when applicable, and accepted required
CTFE result.

### Slice 10A: Extract Assembly Ownership

1. Inventory typed-module construction, selected-module assembly, diagnostic
   aggregation, CTFE artifact attachment, inventories, and Core entry points.
2. Move assembly from `typecheck_bridge.brp` and broad declaration logic into
   `assembly/` without changing output.
3. Keep protocol decoding, tracing transport, and response rendering in the
   bridge.
4. Preserve deterministic module and declaration output order.

### Slice 10B: Checked Graph

1. Define explicit accepted/rejected header, body, and CTFE artifact variants.
2. Construct `CompilerCheckedGraph` from all per-module outcomes.
3. Preserve enough typed recovery information for diagnostics and tools.
4. Avoid optional fields whose validity depends on another status flag.
5. Add tests for mixed accepted/rejected modules and deterministic diagnostics.

### Slice 10C: Codegen-Ready Refinement

1. Define the exact set of headers, bodies, initializers, and CTFE results
   required by a selected compilation target.
2. Validate completeness once at the refinement boundary.
3. Construct opaque `CompilerCodegenReadyGraph` only on complete acceptance.
4. Make Core lowering accept only this type.
5. Delete Core entry points that accept broad typed/recoverable programs.

### Slice 10D: Cutover And Measure

1. Convert compile, check, test, inventory, and LSP/tool consumers to the
   appropriate graph product.
2. Ensure check/tool modes can return useful rejected artifacts without
   accidentally invoking Core.
3. Count body checks, artifact lookups, CTFE evaluations, graph scans, and peak
   memory.
4. Remove repeated typed-module and semantic-header reconstruction.
5. Delete the old broad typed-graph assembly path.

### Phase 10 Exit Criteria

- recoverable checked output and valid Core input are distinct products;
- Core accepts only `CompilerCodegenReadyGraph`;
- no body or header is recomputed during assembly;
- CTFE states are explicit rather than coupled flags/options;
- bridge code orchestrates requests and phase calls only; and
- output and diagnostics remain deterministic.

## Benchmark Matrix

Each phase owns one fast fixture and shares representative acceptance workloads.

| Phase | Fast workload | Required counters |
| --- | --- | --- |
| 1 Identity | declaration-heavy graph | reservations, exact lookups, index builds |
| 2 Module views | high fan-out, tiny exports | path probes, closure visits, binding inserts, view builds |
| 3 Type headers | nested and recursive types | source resolutions, containment scans, header installs |
| 4 Declaration headers | import/trait-heavy graph | signature resolutions, imported installs, candidate visits |
| 5 Globals | annotated/inferred dependency graph | initializer runs, dependency probes, header updates |
| 6 Body context | many independent bodies | context builds, graph copies, local lookups, typed visits |
| 7 CTFE | 24 modules by 32 functions | queued/reached bodies, duplicate requests, body checks |
| 8 Solver | generic/dimension-heavy bodies | meta probes, binds, occurs checks, resolve/zonk visits |
| 9 Validation | large nested typed bodies | node visits by rule, total passes |
| 10 Assembly | overlapping CTFE/output graph | body checks, artifact reuse, graph scans, peak memory |

Existing authoritative fixtures include:

- `benchmarks/compiler_module_binding_profile` for Phase 2;
- `benchmarks/compiler_ctfe_typecheck_profile` for Phase 7;
- `benchmarks/compiler_typecheck_profile` for representative timing;
- `benchmarks/compiler_typecheck_memory` for memory behavior; and
- `benchmarks/compiler_typecheck_name_lookup_profile` for lookup-heavy changes.

Add a new fixture only when an existing one cannot isolate the phase while
remaining representative.

### Measurement Rules

1. Use the same bootstrap compiler, C compiler, flags, fixture, and worker
   configuration for baseline and candidate.
2. Warm up before recording samples.
3. Alternate baseline and candidate runs when machine drift is material.
4. Store raw samples, median, range, checksum, revision, and toolchain metadata.
5. Treat instrumented function times as inclusive unless proven otherwise.
6. Use counters to explain timing, not as substitutes for timing.
7. Reject timing-only changes inside ordinary run-to-run noise.
8. Reject a local optimization that regresses representative low-import or
   low-generic compilation by more than 3% without a larger documented win.
9. Measure peak memory when graph sharing or artifact retention changes.
10. Keep rejected experiments in result notes when they answer a likely future
    question, then remove their code.

## Validation Gates

Use the active Blorp-owned gates. Retired OCaml compatibility/unit/deep gates
are historical evidence only and must not be reintroduced as acceptance gates.

### Fast Slice Loop

Run after each coherent edit:

```bash
make
./blorp test path/to/focused_test.brp
./blorp check --no-format path/to/focused_fixture.brp
git diff --check
```

Use the relevant benchmark's fast mode or smallest stable workload before and
after representation or algorithm changes.

### Compiler Checkpoint Gate

Run before declaring a typechecker slice mergeable:

```bash
make
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test std-check
scripts/test compiler-core-sanitize
scripts/test compiler-blorp-sanitize
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
make quality
git diff --check
```

Focused sanitizer files may be used during development. The checkpoint must run
the broad active sanitizer gates when the phase changes typed-tree ownership,
semantic graph sharing, or body-result lifetime.

Compiler test execution may be partitioned by the repository's current test
runner and CI scripts. Do not infer a semantic failure from a known maximal
single-artifact scale limit; reproduce failures under the supported partitions
and separately track any maximal-artifact runtime/compiler issue.

### Downstream Gate

Run when the phase changes public typed output, Core input, resource facts,
generated code, or compiler packaging:

```bash
scripts/test runtime
scripts/test leak
scripts/test doctest
scripts/test cli
scripts/test lsp
scripts/test package
```

Run `scripts/test` at major phase completion.

## Test Requirements By Boundary

Every phase-product suite must cover:

- valid construction;
- every invalid or contradictory construction state the product removes;
- deterministic identity and source ordering;
- exact diagnostics and source spans for failure cases;
- inability of downstream APIs to accept the previous phase product;
- ownership behavior under shared and uniquely owned values;
- no inappropriate parser or later-phase data in the representation; and
- ordinary, CTFE, check/tool, and Core paths as applicable.

The semantic regression matrix must continue to cover:

- qualified, selective, renamed, cyclic, package, stdlib, private, and
  ambiguous imports;
- records, structs, unions, enums, aliases, opaque types, resources, and
  constructors;
- globals, functions, foreign functions, overloads, generics, and callbacks;
- traits, supertraits, implementations, defaults, ambiguity, and UFCS;
- lambdas, closures, loops, match, propagation, assignment, and control flow;
- tensors, dimensions, ranges, refinements, and subscripts;
- purity, debug restrictions, resources, concurrency, and channels;
- CTFE, selected modules, inventories, Core lowering, and generated C; and
- recovery, deterministic diagnostics, source spans, and failure isolation.

## Mergeability Contract

A slice is safe to merge when:

1. It has one sentence of scope and does not mix unrelated movement,
   representation, semantic behavior, and optimization.
2. Production has one authoritative path for the migrated responsibility.
3. Temporary adapters are either deleted or have a named next slice and no
   semantic ownership.
4. Old fields and helpers have no production readers.
5. Focused characterization and phase-construction tests pass.
6. Applicable active compiler, sanitizer, quality, and downstream gates pass.
7. Benchmark checksum and observable behavior are unchanged unless the slice
   intentionally fixes a tested bug.
8. No generated artifact, untracked migration output, or unrelated formatting
   churn is included.
9. `ARCHITECTURE.md` and this roadmap describe the production state.
10. Work can stop after the slice without leaving two long-term semantic models.

Prefer small reviewable commits during implementation. A later squash does not
justify making the working changes inseparable.

## Stop And Rollback Rules

Stop and narrow or remove a change when:

- a mechanical move changes semantics or diagnostics;
- a phase product needs optional later-phase fields or coupled validity flags;
- production would retain two semantic implementations indefinitely;
- cyclic or ambiguous imports become order-dependent;
- stable IDs change without an explicit compiler reason;
- correctness depends on names, paths, formatting, or declaration-shape
  heuristics after an identity product exists;
- a body needs to mutate an immutable graph fact;
- shared graph correctness depends on COW uniqueness;
- a module split creates cycles, wrapper chains, or duplicated helpers;
- an optimization helps only a microbenchmark while regressing representative
  compilation;
- a benchmark cannot prove it performed equivalent semantic work; or
- several unrelated future phases are required before the current branch can
  merge.

Keep useful tests, counters, traces, and benchmark results separately from a
rejected implementation.

## Immediate Execution Plan

Phase 3 is complete. Phase 3D cut every imported type category over to accepted
headers, Phase 3E retained three measured index corrections, and Slices 3F
through 3H closed the semantic-namespace, value-layout, and parsed-replay
blockers found by the closure audit. The next architectural work begins at
Phase 4; do not add more Phase 3 representations in preparation for it.

### Completed Phase 3E Slice: Known-Type Membership Index

`CompilerTypecheckState.known_type_names` and
`known_resource_type_names` were unordered membership facts implemented as
lists. Registration performed linear duplicate checks and every prescan,
validation, and recursive resource-type query performed another linear scan.
No production consumer observed list order.

The retained representation is one opaque `CompilerKnownTypeIndex` backed by
`Dict[String, CompilerKnownTypeKind]`. `CompilerKnownOrdinaryType` and
`CompilerKnownResourceType` are explicit kinds. Construction is private;
resource insertion records general known-type membership in the same entry, so
the invalid state "resource type is not a known type" cannot be represented.
The named clear transition resets the whole index rather than allowing callers
to clear related fields independently. `ResourceTypeScanContext` retains the
opaque index and performs keyed resource membership queries.

The isolated benchmark is
`benchmarks/compiler_known_type_index_profile`. It registers ordinary and
resource names, repeats duplicate registrations, verifies the resource-subset
invariant, and holds total lookup count at 512,000 while varying index size.
Seven-run medians from the native benchmark were:

| Names per kind | Representation | Registration us | Lookup us |
|---:|---|---:|---:|
| 512 | two lists | 80,421 | 620,027 |
| 512 | one keyed index | 115,731 | 37,295 |
| 2,048 | two lists | 295,442 | 2,340,546 |
| 2,048 | one keyed index | 366,412 | 103,834 |

Lookup time improved by 16.6x at 512 names and 22.5x at 2,048 names. Keyed
registration is 24-44% slower in this isolated workload, but registration
happens once per discovered type while membership is queried repeatedly. At
2,048 names, combined measured work fell from 2.64 seconds to 0.47 seconds.
The checksum and all membership outcomes were unchanged.

`type_homes` is deliberately not part of this slice. It has observable local
override and first-import-wins semantics, so an indexed replacement first needs
collision and deterministic-inventory characterization rather than a blind
membership conversion.

### Completed Phase 3E Slice: Indexed Header Containment

The first representative profile used eight modules with 64 chained record
types and 128 typed function bodies per module: 1,537 declarations including
the target. It produced 512 accepted type headers and 504 declared-type edges.
The workload validates all artifact and declaration counts and retained the
checksum `3083` before and after the change.

The profile exposed an avoidable quadratic path. Resource-containment
completion resolved every declared-type edge with `header_index`, which scanned
the full accepted-header list. After containment, graph construction separately
built the name-bucketed exact-identity index used by normal graph lookup.

The retained representation is a private `CompilerTypeHeaderTable` containing
the ordered header inventory and its `Dict[String, List[Int]]` name buckets.
Its only constructor creates both together before containment. Fixed-point
updates can replace headers at stable positions but cannot independently alter
the index. A name bucket only narrows candidates; `CompilerTypeId` equality
still selects the declaration. A collision regression covers two modules with
the same type name and different resource capabilities.

Seven-run medians from isolated pre-table and post-table profile artifacts were:

| Measurement | Pre-table | Indexed table | Change |
|---|---:|---:|---:|
| Whole typecheck | 1,423,419 us | 1,349,466 us | 5.2% faster |
| Type-header graph build | 68.924 ms | 32.744 ms | 52.5% faster |
| Resource-containment completion | 46.372 ms | 2.980 ms | 93.6% faster |

The pre-table snapshot included the keyed known-type index, so this comparison
isolates header lookup. Raw samples and the exact fixture contract are in
`benchmarks/results/compiler_type_header_lookup_phase3e_2026-08-13.md` and its
adjacent TSV file.

### Completed Phase 3E Slice: Indexed Module Projection

The `mixed` typecheck fixture covers recursive records, nested transparent
aliases, opaque aliases, unions, private declarations, import fan-out, and
qualified imported references. Its production graph contains nine artifacts,
1,073 source and typed declarations, 30 resolved imports, and checksum `3258`.

The profile found 97,920 calls to the full-inventory module-selection predicate
because every category-specific local or public projection rescanned every
accepted header. `CompilerTypeHeaderTable` now constructs graph-ordered all and
public index inventories per exact module identity in a keyed dictionary. A
module storage key owns exactly one inventory, so duplicate module buckets
cannot be represented. The table's private constructor derives those
inventories together with the ordered headers and name buckets; containment can
replace headers only at stable positions. Accepted headers remain the semantic
source of truth.

Twenty-run alternating medians improved from 188,229 us to 184,648 us, or
1.9%. The retained containment control improved by 2.4%, with checksum `3083`
unchanged. Detailed counters, raw samples, and the exact benchmark contract are
in
`benchmarks/results/compiler_type_header_module_projection_phase3e_2026-08-13.md`.

The same profile rejected `type_homes` indexing as the next change. Its measured
lookup and recording path is small, while local override and first-import-wins
semantics require a collision-aware representation. Preserve the current list
until a later profile makes that complexity worthwhile.

### Completed Phase 3 Closure Audit

The audit traced ordinary, CTFE, traced, standalone bridge, and multi-module
test paths. The initial audit found three blockers; Slices 3F through 3H closed
each one and the matrix below records the post-fix state.

| Exit criterion | Verdict | Evidence |
|---|---|---|
| One definition-owned header per named type and constructor | Satisfied | Semantic namespace keys reject duplicate types, traits, and same-parent constructors before header construction. Same-named constructors in different unions and callable overloads remain legal. |
| Typed skeleton identity before header resolution | Satisfied | The bridge builds the complete opaque skeleton graph before alias, parameter, or type-header products. All declaration categories have distinct typed identity variants. |
| Stable trait identities for bounded type declarations | Satisfied | Accepted parameter entries store `CompilerTraitId`; local/imported resolution, duplicate-trait rejection, and unknown-bound rejection are tested. |
| Imports bind identities instead of replaying parsed type declarations | Satisfied | Every graph-capable path requires opaque `CompilerAcceptedTypecheckModule`, derived from a provenance-checked `CompilerAcceptedTypecheckGraph`. The parsed imported-type inventory and all replay APIs have been deleted. |
| Legal recursion and illegal cycles are explicit outcomes | Satisfied | Alias cycles and inline-storage cycles are distinct construction errors. Heap record, union, tuple, tensor, and fixed-array recursion remains legal. |
| No contradictory type-home or containment owners | Satisfied | Graph-backed containment is computed once and installed as an Env projection. Imported type homes and containment cannot be recomputed from parsed declarations. |
| Type-header graph is immutable later-phase input | Satisfied | The graph is opaque; private containment completion precedes its sole constructor, and later paths receive only the completed value. |

Post-fix focused characterization is green: skeleton 8/8, dependency 8/8,
type-header 30/30, bound-module 10/10, bridge 101/101, and declaration 99/99. The
full compiler gate passes 3,438/3,438, and the skeleton and type-header suites
also pass under ASan and UBSan. The new heap-recursion codegen fixture passes
the generated-C warning audit. The repository-wide audit currently reports 14
unrelated stale generated-C text expectations; none involve this fixture or
the type-header pipeline. Recursive semantic conversion itself remains Phase 4
declaration-header work; do not hide it behind a body-local cache.

The final ownership hardening initially rebuilt every importable module from
parsed declarations for every accepted module projection. A single opaque
`CompilerImportableModuleGraph` now owns that body-bearing inventory, while
`CompilerAcceptedTypecheckGraph` validates it against definition-only headers.
This removes repeated semantic work without making parsed bodies part of a type
header. Five uncontended cached `-O2` closure-checkpoint runs retained checksum
`3258` and had a median of 184,527 us, effectively unchanged from the earlier
184,648 us indexed-projection checkpoint. Raw samples and the exact workload
contract are recorded in the Phase 3E module-projection benchmark result. This
measurement must be refreshed whenever the ownership boundary changes.

### Implementation

1. Measure repeated work first; do not introduce caching or interning without
   a counter demonstrating material duplication.
2. Remove one measured redundant resolution, containment scan, or installation
   traversal at a time.
3. Preserve immutable accepted headers and exact identities as the source of
   truth; optimizations may add private indexes but must not add a second
   semantic representation.
4. Re-run the benchmark after each change and retain only improvements that
   preserve checksum, diagnostics, and representative compiler performance.

### Validation

1. Add parity tests before each category cutover for local, selective,
   qualified, private, generic, recursive, and prelude-shadowing cases that
   apply to that category.
2. Keep skeleton, header, bound-graph, declaration, import, CTFE, bridge, and
   Core resolve suites green after each cutover.
3. Run focused ASan/UBSan coverage because accepted headers and converted
   semantic types retain managed graphs.
4. Compare definition IDs, diagnostics, registered types, constructor shapes,
   containment facts, typed inventories, and Core output before and after each
   consumer cutover.
5. Run `make`, active compiler gates, `std-check`, codegen audit, and
   `git diff --check` at every merge checkpoint. Treat maximal-artifact crashes
   separately from semantic failures, but do not merge while either remains
   unexplained.

### Commit Boundary

The current checkpoint completes Phase 3: graph-wide type headers are retained;
builtin/resource, record/struct, union/enum, and transparent/opaque alias facts
are installed from accepted headers throughout production and CTFE paths; and
parsed imported-type replay is deleted. Before a merge, maximal compiler
artifacts must remain stack-bounded; validation includes focused
deep-expression regressions for source finalization, Core SSA, and std
inlining. It also includes a selective-import regression proving that a
prelude-named union payload keeps its exact declaration identity through Env,
trait selection, ownership lowering, and generated C, plus local/imported alias
tests for visibility, generic targets, canonical names, opacity, and type homes.
Graph-backed parsed type replay is gone; adapter-only scaffolding is not a valid
commit boundary.

## Later Optimization Review

After Phase 10, re-profile before choosing more architecture work. Candidate
directions, in measured order, are:

1. interned stable semantic types owned by the completed header graph;
2. broader dense or union-find body-local inference storage;
3. deterministic bounded parallel body checking;
4. secondary trait indexes for still-material candidate sets;
5. typed AST compaction after type identity and tool contracts stabilize;
6. structured semantic diagnostics for LSP/tool consumers;
7. incremental compilation based on explicit phase dependencies;
8. body-local arena-like storage where allocation profiles justify it; and
9. bridge/protocol deletion through the compiler-port roadmap.

These are not implicit requirements of the current phases. In particular,
parallelism and caching must not be used to hide repeated semantic work that the
phase architecture can eliminate directly.

## Definition Of Done

This roadmap is complete when:

1. Production exposes precise indexed, bound-module, type-header,
   declaration-header, completed-header, inferred, solved, validated, checked,
   and codegen-ready products or equivalently strong types.
2. Semantic declarations are resolved once per defining module.
3. Imports bind identities and visibility without semantic declaration replay.
4. Trait and callable relationships use stable identities after resolution.
5. Every usable global has a real declared or inferred type; pending and
   rejected initializers are distinct states.
6. Body checks use immutable graph/module context and isolated inference state.
7. No inference metavariable can escape a solved body.
8. No rejected header, body, or CTFE artifact can enter Core lowering.
9. CTFE checks only definition-reachable bodies and reuses accepted artifacts.
10. Typechecking order does not affect IDs, diagnostics, or typed output.
11. Safety checks run at the earliest sound phase and avoid unjustified
    duplicate traversals.
12. Every phase has focused construction/rejection coverage and a fast
    deterministic benchmark.
13. Superseded broad state, imported registration, eager CTFE, and assembly
    paths are deleted.
14. Active Blorp-owned compiler, sanitizer, quality, and applicable downstream
    gates pass.
15. `ARCHITECTURE.md`, this roadmap, and production ownership agree.

## Historical Evidence

Detailed samples remain in `benchmarks/results/`. The most relevant records are:

- `compiler_definition_plan_baseline_2026-08-02.tsv`;
- `compiler_definition_index_phase1b1_2026-08-02.tsv`;
- `compiler_indexed_graph_phase1b2_2026-08-02.tsv`;
- `compiler_definition_index_phase1b3_2026-08-03.tsv`;
- `compiler_import_graph_phase1b3_2026-08-03.tsv`;
- `compiler_module_binding_phase2_baseline_2026-08-04.tsv`;
- `compiler_module_binding_phase2_checkpoint_a_2026-08-04.tsv`;
- `compiler_module_binding_phase2b1_2026-08-11.tsv`; and
- `compiler_module_binding_phase2b2_2026-08-11.tsv`; and
- `compiler_ctfe_typecheck_profile_2026-08-10.md`; and
- `compiler_type_header_lookup_phase3e_2026-08-13.md`.

Historical references to OCaml `compiler-unit`, `compiler-deep`, or similar
gates describe the repository at the time those measurements were recorded.
They are not current acceptance requirements.
