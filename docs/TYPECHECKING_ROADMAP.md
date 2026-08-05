# Typechecking Architecture Roadmap

Status: active implementation. Phase 0 and Phase 1 are complete. Phase 2,
module binding and visibility views, began with its focused measurement and
current-state audit on 2026-08-04.

Scope: the Blorp-owned module, type, inference, validation, and typed-graph
pipeline. This roadmap does not add source-language features, persistent caches,
or an OCaml implementation.

This document is the single execution roadmap for typechecking architecture and
typechecking performance. It supersedes and replaces the former resolved-module-
interfaces roadmap. Use:

- [ARCHITECTURE.md](ARCHITECTURE.md) for the production compiler pipeline;
- [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) for broader compiler priorities;
- [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md) for deleting
  the remaining OCaml host and tool implementation; and
- this document for the order, contracts, tests, measurements, and merge points
  of typechecker restructuring.

## Progress

### 2026-08-02: Definition-Planning Boundary

Completed the first mergeable slice:

- moved the initial `CompilerGraphDefinitionPlan` and all reservation traversal
  out of `compiler_typecheck_bridge.brp` into a graph-owned module; Phase 1B1
  subsequently replaced that migration record with the opaque definition
  index described below;
- kept target-first ID order, raw-map representation, and downstream state
  injection unchanged;
- added direct coverage for functions, overloads, foreign functions, private
  functions, constructors, traits, implementations, default methods, exact ID
  order, and repeated-program deduplication;
- added a planner-only benchmark whose measured loop receives parsed programs
  and calls the same production planner used by the bridge;
- recorded a seven-run baseline in
  `benchmarks/results/compiler_definition_plan_baseline_2026-08-02.tsv`; and
- passed the compiler and compiler-deep gates: 4,691 tests with zero failures.

The extraction clarified one ownership detail. Callable and source-definition
keys and their equality operations are shared by indexing and typecheck-state
lookups; they are not bridge-private helpers. Phase 1B1 therefore gives that
identity substrate a graph-owned home before prepared modules move into the
full indexed graph.

Two additional parity constraints became explicit:

- the bridge obtains the initial user definition ID from a freshly initialized
  typecheck environment; Phase 1B1 makes that an explicit opaque index seed,
  and Phase 1B2 exposes that seed directly from the centralized initial
  typecheck environment; and
- current planning gathers default-method names graph-wide and reserves every
  gathered name at every implementation span. The extraction tests protect the
  resulting ID behavior, but Phase 1B must model trait-keyed defaults explicitly
  before deciding whether unused reservations can be removed without violating
  deterministic-ID requirements.

### 2026-08-02: Opaque Definition Index

Completed Phase 1B1:

- moved callable and source-definition keys and equality into
  `graph/compiler_definition_identity.brp`;
- replaced the constructible plan record with opaque
  `CompilerDefinitionIndex` and `CompilerDefinitionIndexSeed` values;
- made `CompilerTypecheckState` hold one index rather than two public maps;
- removed raw-map injection and the old graph-definition-plan module;
- added exact lookup, read-only inventory, copy-on-write upsert, and monotonic
  frontier operations;
- proved that installing or updating an index cannot move `env.next_def_id`
  backward, even while broad typecheck state still permits independent
  environment evolution;
- added a compile-fail test proving outside code cannot construct an index
  representation; and
- passed 1,490 compiler tests and 3,206 compiler-deep tests.

The same 681-definition benchmark retained checksum 172250. Seven candidate
samples had a 44,694 microsecond median, 15.2% below the Phase 1A baseline. The
result is recorded in
`benchmarks/results/compiler_definition_index_phase1b1_2026-08-02.tsv`.

### 2026-08-02: Indexed Graph Phase Product

Completed the structural Phase 1B2 boundary:

- introduced opaque `CompilerModuleIdentity`, `CompilerIndexedGraph`, and
  `CompilerPreparedModule` values under `stage_06_typecheck/graph/`;
- made prepared-module construction require `FinalizedTypecheckProgram`, then
  store the proven-finalized parsed program without an additional wrapper at
  the later graph/typecheck boundary;
- made graph construction return
  `Result[CompilerIndexedGraph, List[CompilerIndexedGraphError]]`, so duplicate
  dependency or target/dependency identities cannot expose a partial graph or
  definition index;
- made exact dependency selection return a `Result` and reject unknown or
  repeated requested targets before importable-module or CTFE preparation;
- made rejected bridge requests emit only a target diagnostic artifact, never
  partially typechecked dependency artifacts;
- centralized the initial definition-index seed at typecheck-state
  initialization so graph construction no longer creates a broad temporary
  state merely to discover the builtin definition frontier;
- made the bridge and CTFE preparation consume the accepted module set and the
  definition index through `CompilerIndexedGraph` accessors;
- added direct graph-product, exact-selection, bridge integration,
  all-or-nothing rejection, and opaque-construction regressions;
- made local type-alias registration canonicalize imported representation
  types, covering opaque types over imported managed records; and
- retained all production workload counts and checksum 2913.

The production import-heavy workload remains at parity. Seven final interleaved
samples against current main had a 558,242 microsecond main median and a 562,356
microsecond Phase 1B2 median, a 0.7% increase within the observed timing
variance. Both setup medians were 425,120 microseconds. Results are in
`benchmarks/results/compiler_indexed_graph_phase1b2_2026-08-02.tsv`.

Validation included 1,493 compiler tests, 4,843 runtime tests, 585 compiler-unit
tests, 3,217 compiler-deep tests, and the focused graph, bridge,
source-finalization, and opaque-alias regressions under ASan and UBSan, all with
zero failures.

That boundary exposed a correctness gap: callable and source-definition keys
identified declarations by source span without including
`CompilerModuleIdentity`, so distinct canonical modules backed by the same
source path and span could collide. Phase 1B3 below closes that gap.

### 2026-08-03: Module-Scoped Declaration Identity

Implemented the Phase 1B3 typecheck boundary:

- moved module-loading products into
  `stage_04_modules/compiler_loaded_module.brp` and made resolver identities,
  module load candidates, accepted loaded modules, module identities, prepared
  modules, indexed graphs, definition indexes, and typecheck module scopes
  opaque;
- kept the source module name and resolver-selected canonical path as distinct
  facts, so aliasing or mounting one source under different legal canonical
  identities does not rewrite source spans or parser identity;
- added `CompilerModuleIdentity` to callable and source-definition keys and
  covered identical paths/spans under distinct canonical modules; the keys are
  opaque so their identity facts cannot be constructed inconsistently;
- replaced overwrite-capable index updates with conflict-rejecting insertion,
  including repeated identical bindings, key remapping, same-ID reuse, and
  cross-kind reuse;
- centralized the only constructible initial definition-index seed, made
  environment-derived seed construction private, and removed caller-supplied
  seeds from public indexed-graph construction;
- made graph-prepared states reserve IDs read-only while direct single-module
  states remain explicitly extensible; missing reserved IDs now fail closed;
- made module identity, definition-ID policy, and module origin one opaque
  state scope, so they cannot be independently updated;
- made the indexed graph own its definition index exactly once and introduced
  graph-compatible prepared scopes; allocation identity is only an O(1) fast
  path, with exact module identity, origin, order, and parsed-program comparison
  as the semantic fallback, so pure behavior never depends on allocation;
- made independently built but semantically identical graphs compatible while
  graphs that differ in canonical identity, origin, module order, or parsed
  program fail closed instead of replacing or borrowing the current index;
- replaced source-name first-match import lookup with an explicit
  missing/found/ambiguous result, canonical-path precedence, and sorted
  order-independent ambiguity diagnostics; dependency closure now retains all
  ambiguous candidates so registration cannot silently collapse them first;
- made failed index insertion return a failed claim, preserved the monotonic ID
  frontier when leaving temporary body environments, and covered two defaulted
  implementations receiving distinct callable IDs;
- converted recursive local and imported implementation-method collection to
  state-threading loops; and
- made bridge execution consume a packaged per-module work item containing the
  prepared scope and one shared import/CTFE context, so typed-module helpers
  cannot pair an AST or scope with context from another graph; graph-scoped
  state is constructed from that scope rather than an index copied into each
  prepared module.

The optimization pass found two representations that looked attractive but
failed measurement: nested persistent module/name maps copied too much during
index construction, while cached structural hashes cost too much on transient
lookup keys. The retained index uses one module-display-name bucket per key kind
and exact opaque-key equality inside that short bucket. Display names affect
only search cost; they never define identity. A regression covers two direct
modules that share a display name but differ in source path.

The declaration-index benchmark initially exposed a 15% regression because the
lower-level repeated operation reconstructed the complete builtin environment
to recover its seed. The final API keeps public graph construction responsible
for obtaining the centralized opaque seed, while allowing the repeated
lower-level operation to receive that proven seed. Seven interleaved final
samples retained 641 callable IDs, 40 source IDs, 681 allocations, and checksum
172250. Median measured time was 49,462 microseconds at the branch point and
13,843 microseconds for Phase 1B3, a 72.0% decrease. Fixture setup increased
5.7%, from 22,461 to 23,743 microseconds. Results are in
`benchmarks/results/compiler_definition_index_phase1b3_2026-08-03.tsv`.

The production import-heavy workload retained 31 artifacts, 1,021 source and
typed declarations, 420 resolved imports and bindings, zero errors, and
checksum 8739 over three iterations. The first correct implementation regressed
11.5% because every import declaration rescanned all candidate modules to prove
ambiguity. Exact canonical paths are now indexed once per registration batch,
while alias lookup retains the complete deterministic ambiguity check. Seven
final interleaved samples had a 1,247,560 microsecond branch-point median and a
1,312,024 microsecond Phase 1B3 median, a 5.2% increase; setup increased 0.5%.
This residual cost is tracked by Phase 2, which will build one graph-owned
canonical and alias index and delete arbitrary list-based module lookup rather
than weakening ambiguity semantics. Results are in
`benchmarks/results/compiler_import_graph_phase1b3_2026-08-03.tsv`.

One ownership boundary remains deliberately explicit. Canonical path and module
origin now cross module loading together as one opaque
`CompilerResolvedModuleIdentity`, so later phases cannot vary either fact
independently. The production CLI resolver still constructs
`CliFrontendModuleGraph` in Stage 12, however, and the Stage 06 bridge adapts
its raw request record into that identity. Phase 2 begins by moving the
resolver-produced graph product and request adaptation to Stage 04; until then,
the bridge input remains a trusted compiler-internal resolver assertion rather
than independently proven filesystem provenance.

Two hardening boundaries intentionally move with that Phase 2 work. The full
`CompilerTypecheckState` record is still public because inference and
declaration code update many of its fields directly; Phase 2 must introduce an
opaque graph/module view before making graph-scoped state itself opaque. The
exact structural graph-compatibility fallback is deliberately cold: production
work items share one graph allocation and take the O(1) identity fast path.
Phase 2 should delete arbitrary cross-graph importable-module inputs rather
than cache or weaken that exact fallback.

Final Phase 1 cleanup replaced closed CTFE and graph-module states with enums,
used stack structs for primitive-only ownership and benchmark carriers, removed
a migration-era full-length `String.substring` copy from bridge JSON field
extraction, and replaced two single-output list builders with direct selection
operations. The bridge ownership suite passed all 94 tests under ASan and
UBSan after the string copy was removed. Nine interleaved final samples found
no material measured-loop regression: definition-index time changed from
22,169 to 22,014 microseconds and import-graph time from 1,787,509 to 1,796,875
microseconds. Import fixture setup decreased from 447,964 to 421,604
microseconds. Raw samples are in
`benchmarks/results/compiler_phase1_final_cleanup_2026-08-03.tsv`.

An attempted allocation cleanup exposed a separate bootstrap limitation:
direct opaque aliases over imported managed types are accepted by the current
development compiler but rejected by the pinned bootstrap compiler because the
unqualified underlying type and its canonical qualified identity diverge.
`FinalizedTypecheckProgram` and `CompilerPreparedModule` therefore retain their
one-field opaque record representations. Removing those allocations must wait
for a focused imported-opaque-alias type-identity fix; it is not a prerequisite
for Phase 2.

Final validation passed 585 compiler-unit tests, 1,501 compiler tests, and
3,248 compiler-deep tests with zero failures. The focused sanitizer matrix
passed 135 finalization, graph, definition-index, import, and bridge tests. On
this machine the first combined compiler-deep debug harness made progress more
slowly than the default 180-second watchdog; the unmodified gate passed with
the documented `BLORP_COMPILER_TEST_TIMEOUT=600` override. The harness remained
CPU-active and completed, so this was a local progress-bound issue rather than
a deadlock or semantic failure.

A final hardening review closed three definition-index correctness gaps before
Phase 1 completion:

- default methods now remain associated with their declaring module and trait;
  each implementation reserves only defaults from the trait it actually names
  and does not reserve a synthesized default that it overrides explicitly;
- imported and compiler-prelude trait defaults use explicit visibility facts
  rather than a graph-wide method-name list; index planning and body
  materialization share one exact prelude-traits module predicate that requires
  standard-library origin plus the canonical/source module identity, so user,
  package, or unrelated standard-library modules cannot create phantom
  callable IDs at an implementation span; and
- target definitions remain first, while dependency definitions are reserved
  in canonical-module order. Equivalent dependency input orders therefore
  receive identical IDs without changing the graph's preserved module order or
  its order-sensitive scope-compatibility contract.

The review also made the shared compiler-benchmark runner include and hash
Blorp compiler `.h` inputs, preventing stale artifacts and allowing benchmarks
that transitively use the indexed-graph FFI boundary to compile. An explicit
benchmark workspace root now binds the benchmark source graph, default compiler
and bridge, hashes, native headers and include path, `blorp.toml`, and working
directory to one checkout. A build-configuration regression and fresh-cache
native benchmark build cover that contract. Post-hardening smoke runs retained
the declaration-index workload's 641 callable IDs, 40 source IDs, 681
allocations, and checksum 172250, and the import workload's 31 artifacts, 1,021
source and typed declarations, 420 resolved imports and bindings, zero errors,
and checksum 8739. Concurrent test activity from another worktree made those
non-interleaved timings unsuitable as a replacement for the controlled result
above.

Comprehensive hardening validation passed 585 compiler-unit tests, 1,504
compiler tests, 3,252 compiler-deep tests, 241 focused Phase 1 tests, and 143
focused sanitizer tests with zero failures. After the independent follow-up
review tightened prelude identity and benchmark workspace ownership, the pinned
self-hosted build and 2,089 compiler-unit/compiler tests passed again; an
additional 206 focused tests passed in both normal and sanitizer modes. A probe
also confirmed that selective trait aliases are not yet carried through
implementation-body trait lookup even though the index resolves the aliased
import binding and tests that reservation. Phase 2 owns that module-view
correction; Phase 1 does not add a second alias-resolution path.

### 2026-08-04: Phase 2 Measurement Boundary

Established the independently mergeable Phase 2 preparation checkpoint:

- added a direct module-binding benchmark whose measured loop calls production
  `compiler_register_program_imports` on pre-parsed module surfaces;
- mixed exact canonical paths with alternate source module names, and combined
  one selective symbol with one explicit module alias per import;
- selected the final export from each surface so the current symbol-list scan
  has stable, visible pressure without adding expression inference;
- validated module aliases, selective names, total binding count, diagnostics,
  checksum, and repeat determinism in a compiler-owned test; and
- recorded the then-current compiler revision `ec789a655903a32d13c505cd29557637bc29f180`
  baseline in
  `benchmarks/results/compiler_module_binding_phase2_baseline_2026-08-04.tsv`.

At 100 iterations, 64 modules, and 16 exports per module, nine warm plain-mode
samples had a 63,397 microsecond elapsed median and an 18,389 microsecond setup
median. One instrumented iteration confirmed 64 import declaration lookups,
2,048 alternate-name matcher calls from 32 fallback probes over 64 candidates,
64 surface-symbol lookups, 64 alias registrations, 64 imported-name
registrations, and 128 semantic import-binding deduplication lookups in timed
registration. Those binding lookups represent 8,128 baseline list-entry
comparisons. Post-timing validation deliberately adds 128 more binding lookups
to verify the observable lookup API, so whole-process function profiles report
256 calls. The logical lookup counts remain fixed after indexing; comparison
pressure plus elapsed and inclusive function time define the optimization
target.

The audit also revised the Phase 2 starting point. Phase 1/main already provide
a batch-local exact canonical-path index plus keyed imported-name and local
top-level-name lookup. Module aliases and import-binding deduplication remain
list-based, alternate-name ambiguity still rescans every candidate module, and
the public typecheck state still permits its source-order imported-name list and
keyed lookup table to disagree. Phase 2 must preserve the existing indexes while
moving their construction behind an opaque module-view boundary, rather than
reimplementing or temporarily removing them.

## Executive Decision

Restructure typechecking one explicit phase at a time. For each phase:

1. mechanically move its existing responsibility into a dedicated module or
   small directory without changing behavior;
2. replace general-purpose state at its boundary with a phase-specific input
   and output type;
3. switch production to that boundary and delete the superseded path;
4. prove semantic and diagnostic parity; and
5. make one straightforward, separately measured optimization using a small,
   deterministic benchmark.

Every numbered checkpoint must be independently suitable for merging to main.
No checkpoint may depend on a large unfinished rewrite remaining on the branch.
Larger optimizations discovered during a phase are recorded as either an
immediate follow-on slice or a post-decomposition opportunity; they are not
silently absorbed into the mechanical extraction.

The intended architecture is definition-owned rather than importer-owned:

```text
ParsedModuleGraph
  -> CompilerIndexedGraph
  -> CompilerBoundModuleGraph
  -> CompilerTypeHeaderGraph
  -> CompilerCallableHeaderGraph
  -> CompilerDeclarationHeaderGraph
  -> CompilerHeaderGraph
  -> CompilerBodyCheckContext + CompilerInferSession per body
  -> CompilerInferredBody
  -> CompilerSolvedBody
  -> CompilerValidatedBody
  -> CompilerTypedGraph
```

Graph-wide semantic facts are immutable and shared. Module views own aliases,
selective imports, and visibility. Function bodies own only lexical and
inference state. A later phase cannot be invoked with an earlier or partially
initialized value.

## Why This Order

The production typechecker already has strong local algorithms, but their
ownership boundaries are too broad:

- `CompilerTypecheckState` combines graph identity, imports, module policy,
  lexical scopes, traits, implementations, inference context, resources,
  diagnostics, and memos.
- graph definition IDs are reserved once, but the plan is private to the bridge
  and copied into every module's general state;
- importable modules retain parsed declarations, and semantic type, callable,
  trait, and implementation registration is replayed for importing modules;
- recursive `CompilerType` values and list-backed metavariable bindings make
  common inference operations structurally expensive;
- body inference and validation are difficult to run independently because
  they thread the same broad state; and
- `compiler_infer.brp` owns several distinct responsibilities in one large
  module, making local changes harder to understand and benchmark.

The dependency order is therefore:

1. establish stable graph identity;
2. establish module-local visibility without semantic reconstruction;
3. resolve type identities and definitions;
4. resolve callable signatures and declared global types;
5. resolve traits and implementations;
6. infer unannotated global binding types and complete the header graph;
7. give ordinary bodies a read-only semantic context and local inference
   session;
8. separate inference from solving/finalization;
9. make semantic validation an explicit result; and
10. assemble the typed graph and CTFE artifacts from completed phase products.

This ordering avoids rewriting inference against another temporary environment.
It also makes the largest known optimization, resolving imported declarations
once per defining module, a normal consequence of the header phases rather than
an isolated special case.

## Goals

1. Make phase ordering explicit in types.
2. Make each semantic declaration owned by its defining module and resolved no
   more than once per compilation graph.
3. Keep module aliases, selective imports, and visibility module-local.
4. Keep function-local metavariables, substitutions, lexical scopes, and
   diagnostics out of graph-wide state.
5. Preserve deterministic IDs, diagnostics, typed AST, CTFE behavior, and Core
   input throughout migration.
6. Reduce repeated semantic work before considering persistent caching.
7. Enable deterministic parallel body checking eventually, without making
   parallelism a prerequisite for the architectural cleanup.
8. Leave the codebase smaller or more coherent after each completed phase; do
   not accumulate permanent facades or dual paths.
9. Maintain a fast benchmark loop that attributes each performance result to
   one change.
10. Keep main releasable and tests passing after every checkpoint.

## Non-Goals

- Persistent or cross-invocation typechecking caches.
- A universal incremental-query framework.
- Source-language changes.
- Replacing the typed AST or Core IR during phase extraction.
- A big-bang `CompilerType` interning rewrite.
- Parallel module or body checking before graph facts are immutable and
  diagnostics are deterministic.
- Renaming all stage directories in one mechanical change.
- Porting or preserving OCaml typechecking code.
- Optimizing unrelated Core, codegen, runtime, or test-runner work.

## Current Evidence

The import-heavy benchmark in
`compiler/blorp/benchmarks/compiler_import_graph_profile.brp` constructs a
30-module graph with 32 functions per module and import fan-out 20. The measured
fixture contains:

- 420 resolved import edges;
- 960 module functions;
- 13,440 imported-function registration opportunities; and
- qualified calls that require every imported function to remain usable.

One retained-program profile reported these inclusive costs:

| Function family | Time | Calls |
| --- | ---: | ---: |
| graph typecheck workload | 3,671 ms | 1 |
| register import modules | 2,635 ms | 31 |
| register direct import declarations | 2,562 ms | 420 |
| register imported signatures | 2,477 ms | 420 |
| register imported function | 2,370 ms | 13,440 |
| register function from semantic types | 1,492 ms | 13,440 |
| resolve imported annotations | 695 ms | 26,880 |

These rows are inclusive and must not be added together. They demonstrate that
semantic reconstruction scales with import edges rather than declarations.

An earlier parsed-declaration classifier and opaque importable-module wrapper
did not remove that reconstruction. Its eight-sample median was approximately
3% slower than baseline. A representation that merely classifies parsed input
is not a resolved semantic header and is not an accepted optimization.

An orthogonal exact callable-ID lookup index produced a strong preliminary
improvement, showing that phase-local indexing can be worthwhile. It did not
change importer-owned semantic reconstruction. Both lessons guide this plan:

- remove repeated construction at phase boundaries; and
- then optimize the remaining local lookup using explicit indexes.

The Phase 1A planner-only baseline uses 20 modules with 32 functions and two
constructors per module, repeated 25 times. It validates 641 callable IDs, 40
source IDs, 681 total allocations, and checksum 172250 on every run. Seven
release-mode samples had a 52,702 microsecond median measured planner time;
fixture construction and parsing are reported separately.

## Architectural Principles

### Phase Products, Not Flags

Use distinct types for distinct completion states. Do not add fields such as:

```text
headers: Option[CompilerHeaderGraph]
has_solved_types: Bool
resources_validated: Bool
```

A function requiring resolved headers must accept `CompilerHeaderGraph` or a
context constructible only from one. A solved body must not share a public
constructor with a body that may still contain metavariables.

### Definition-Owned Facts

The defining module owns canonical semantic declarations. Import edges own only
binding and visibility decisions. Installing or viewing an imported declaration
must not parse annotations, qualify its defining types, recompute generic
bounds, infer resource policy, or mint a new definition ID.

### Local Mutable State Is Local

Blorp permits local mutation and uses value semantics. Exploit that model:

- immutable graph data may be shared across body checks;
- an inference session may update uniquely owned local tables;
- no body check may mutate the semantic graph or another body's state; and
- no optimization may depend on accidental COW uniqueness for correctness.

### Recovery Is Explicit

The compiler must continue after many source errors, but a diagnostic-bearing
artifact must not be mislabeled as validated. Prefer outcomes shaped like:

```blorp
union CompilerBodyCheckOutcome:
    CompilerBodyAccepted(CompilerValidatedBody)
    CompilerBodyRejected(CompilerRecoverableTypedBody, List[CompilerDiagnostic])
```

The exact names may change, but successful and recoverable-invalid states must
remain distinct.

### Stable Identity Before Optimization

Use graph-assigned identities for modules, definitions, types, traits,
implementations, locals, metavariables, and resource scopes where the
distinction affects correctness. Do not infer identity from source names,
generated names, module prefixes, or spans after the indexing phase.

The first extraction may retain existing `Int` representation behind an opaque
API. Introduce distinct ID wrappers incrementally; do not block phase separation
on a repository-wide ID conversion.

### No Permanent Compatibility Layer

A short-lived adapter may keep a checkpoint small, but it must have a named
consumer and deletion condition. When production switches to a phase product,
delete the old path in the same checkpoint or the immediately following
checkpoint. Do not maintain parsed and resolved semantic registration paths.

## Target Ownership Boundaries

### Stage 04: Syntactic Modules

Stage 04 continues to own module identity discovered during loading,
authoritative syntactic surfaces, and resolved source-graph edges. It must not
resolve semantic types or callable signatures.

### Stage 05: Shared Semantic Primitives

Stage 05 continues to own semantic type syntax, canonical type operations,
dimension solving, refinements, and other algorithms shared by several
typechecking phases. It must not own module orchestration or body-local state.

### Stage 06: Typechecking Phases

Organize Stage 06 by responsibility as extraction proceeds:

```text
stage_06_typecheck/
  graph/          declaration identity and indexed graph
  modules/        import binding, visibility, and module views
  headers/        type, value, callable, trait, and implementation headers
  body/           body context, inference session, expression inference
  validation/     purity, resource, match, tailrec, and body validation
  assembly/       typed module graph, CTFE scheduling, artifact assembly
```

Do not create every directory in advance. Create a directory when its first
cohesive production responsibility moves. Keep source moves mechanical and
reviewable.

### Stage 09 And Later

Core lowering receives a completed typed graph. Core must not compensate for
missing typechecking phase facts or repeat source-level call, trait, purity, or
resource resolution.

## Phase Type Sketch

Names are directional, not mandatory. Prefer local naming precedent when it is
clearer.

```blorp
opaque type CompilerIndexedGraph = CompilerIndexedGraphRep
opaque type CompilerBoundModuleGraph = CompilerBoundModuleGraphRep
opaque type CompilerTypeHeaderGraph = CompilerTypeHeaderGraphRep
opaque type CompilerCallableHeaderGraph = CompilerCallableHeaderGraphRep
opaque type CompilerDeclarationHeaderGraph = CompilerDeclarationHeaderGraphRep
opaque type CompilerHeaderGraph = CompilerHeaderGraphRep

opaque type CompilerModuleView = CompilerModuleViewRep
opaque type CompilerBodyCheckContext = CompilerBodyCheckContextRep
opaque type CompilerInferSession = CompilerInferSessionRep

opaque type CompilerInferredBody = CompilerInferredBodyRep
opaque type CompilerSolvedBody = CompilerSolvedBodyRep
opaque type CompilerValidatedBody = CompilerValidatedBodyRep
opaque type CompilerTypedGraph = CompilerTypedGraphRep
```

Each later graph phase may contain or consume the preceding phase product. Do
not duplicate large graph records merely to change a type name. Use opaque
representations and bulk operations so generated ownership retains shared data
instead of recursively rebuilding it.

## Universal Phase Workflow

Every phase below follows four mergeable checkpoints.

### Checkpoint A: Mechanical Separation

1. Characterize current behavior with focused tests.
2. Move one cohesive responsibility and its private helpers.
3. Preserve public signatures and execution order through a narrow adapter.
4. Update imports and tests without changing semantic output.
5. Run focused tests, the compiler gate, formatting, and `git diff --check`.

This checkpoint makes no performance claim. A file move that changes timing is
noise unless separately measured.

### Checkpoint B: Phase-Specific Types

1. Introduce an opaque input/output type with smart constructors.
2. Move validation to the construction boundary.
3. Prevent callers from fabricating contradictory state.
4. Add negative unit tests for invalid construction or phase misuse.
5. Keep a single temporary adapter only when required for the production switch.

### Checkpoint C: Production Cutover And Parity

1. Route the production pipeline through the phase type.
2. Delete the superseded construction or registration path.
3. Compare diagnostics, typed AST, stage inventories, CTFE artifacts, and Core
   output on focused fixtures.
4. Run sanitizer and leak coverage when managed graph data changes ownership.
5. End with a clean, mergeable tree and no feature flag.

### Checkpoint D: Straightforward Optimization

1. Choose one measured local inefficiency owned by the phase.
2. Add a deterministic operation count where wall time alone is ambiguous.
3. Record baseline and candidate measurements with the same compiler and flags.
4. Keep the optimization only when the result is clear and maintainability does
   not regress.
5. Store durable measurements under `benchmarks/results/`.

If the optimization requires another phase's ownership to be settled, record it
under post-decomposition opportunities and move on.

## Phase 0: Baseline And Observation Contract

### Goal

Create a trustworthy fast feedback loop before restructuring production.

### Work

1. Keep the existing import-graph, typecheck-profile, alias-resolution, and
   typecheck-memory fixtures passing.
2. Add a common phase benchmark configuration with a small fast mode and a
   larger acceptance mode.
3. Record deterministic checksums and semantic work counters in addition to
   elapsed time.
4. Add trace boundaries for each current coarse step before moving it.
5. Record a clean baseline from the pinned bootstrap compiler.

### Fast Mode

Fast mode should complete in seconds and be suitable after each edit. Prefer a
small in-process graph and enough iterations to make regressions visible. It
must assert:

- zero unexpected diagnostics;
- exact module, declaration, import, and typed-body counts;
- a stable checksum over typed outputs or inventories; and
- no generated artifacts left in the repository.

### Acceptance Mode

Use the existing import-heavy graph and representative low-import fixture. Run
at least seven alternating baseline/candidate samples after warmup for a local
decision and nine when recording a final architectural result.

### Exit Criteria

- one documented fast command exercises production typechecking;
- phase counters and checksums are tested;
- the baseline result is committed under `benchmarks/results/`; and
- benchmark-only workers cannot become an alternate production compiler path.

## Phase 1: Graph Identity And Declaration Indexing

### Goal

Make stable graph identity a completed phase rather than private bridge state.

### Current Responsibility

`graph/compiler_indexed_graph.brp` now owns canonical prepared modules, rejects
duplicate module identities, builds exact dependency lookup, and contains the
opaque `CompilerDefinitionIndex`. `CompilerTypecheckState` shares that index
directly. `compiler_typecheck_bridge.brp` adapts bridge requests into prepared
modules and owns later importable-module and CTFE preparation.

### Checkpoint A: Mechanical Separation (Complete)

Move the definition-plan record, reservation traversal, and inventory counters
into `stage_06_typecheck/graph/`. Leave bridge orchestration, shared identity-key
semantics, and ID order unchanged. Move shared key ownership only with the
`CompilerIndexedGraph` boundary in Checkpoint B.

### Checkpoint B1: Identity And Opaque Index (Complete)

Move shared source identity out of broad typecheck state. Replace constructible
maps and counters with an opaque `CompilerDefinitionIndex`, require an explicit
seed, and install the index into typecheck state as one value.

### Checkpoint B2: Indexed Graph Phase Type (Complete)

Introduce `CompilerIndexedGraph` containing:

- prepared modules and canonical module identities;
- deterministic declaration IDs;
- exact lookup indexes needed by later phases; and
- the next free definition ID required by Core and generated declarations.

Construction rejects and diagnoses duplicate canonical module identities.
Unknown or repeated requested dependency targets are also rejected. Rejected
construction exposes no graph, and later phases receive the indexed graph, not
raw maps plus a counter.

### Checkpoint B3: Module-Scoped Declaration Identity (Complete)

Add `CompilerModuleIdentity` to callable and source-definition keys. Every
planner traversal and typecheck lookup must construct the same module-scoped
key. Replace overwrite-capable public index updates with conflict-rejecting
operations so an exact declaration key cannot silently change definition ID.
Move accepted canonical identity construction behind the module-loading
boundary. Canonical path and origin are one opaque resolver identity;
load-candidate and accepted-module representations are opaque. Phase 2 moves
the resolver-produced graph from Stage 12 to Stage 04 so ordinary bridge
request records are no longer able to assert canonical provenance directly.

Cover distinct canonical modules sharing a source path, repeated identical
lookups, conflicting ID insertion, imported/default methods, and fallback
single-module typechecking. Construction must diagnose contradictory keys
without passing an inconsistent index to later phases.

### Checkpoint C: Parity (Complete)

Prove identical IDs across repeated runs, equivalent module input orders,
overloads, foreign declarations, constructors, traits, implementations, default
methods, CTFE reuse, typed AST, and Core.

### Checkpoint D: Simple Optimization (Complete)

Build exact indexes once and remove per-module index rebuilding or name-bucket
scans that the graph can answer directly. Target definitions remain first and
dependencies use canonical-module order for stable IDs; this ordering belongs
only to definition reservation and does not reorder graph output. The retained
module-scoped declaration index completes this work; Phase 2 owns the remaining
graph-wide import alias index.

### Benchmark

Use a declaration-heavy graph varying modules and declarations per module.
Count reservations, exact lookups, duplicate probes, and per-module index
installations.

### Exit Criteria

- the bridge does not own definition-plan algorithms;
- body and header phases cannot mint replacement source IDs;
- all downstream IDs come from `CompilerIndexedGraph`; and
- the old raw-map injection API is deleted.

## Phase 2: Module Binding And Visibility Views

### Goal

Separate source import syntax and module-local visibility from semantic
declaration construction.

### Current Responsibility

Import registration currently mixes loaded-module validation, aliases,
selective bindings, private-export diagnostics, imported-name tracking, and the
selection of parsed declarations to register.

### Checkpoint A: Mechanical Separation (Complete)

Move the existing dedicated `compiler_imports.brp` substrate to
`modules/compiler_module_binding.brp`, plus module
matching, import-path resolution, default aliases, selective bindings,
visibility diagnostics, dependency closure, and ambient-module rules currently
left in `compiler_typecheck_decl.brp`, under `stage_06_typecheck/modules/`.
Preserve current imported-name and binding outputs. This checkpoint is a move
and dependency-direction cleanup, not a second import implementation.

Completed on 2026-08-04. Importable-module facts and source import registration
now live in `modules/compiler_module_binding.brp`; module identity matching,
direct and transitive visibility, and ambient implementation selection live in
`compiler_module_visibility.brp`; prelude projection lives in
`compiler_module_prelude.brp`; and the small program-level composition boundary
lives in `compiler_module_selection.brp`. The declaration checker consumes
these modules and retains semantic Env registration. This checkpoint moved the
existing algorithms without changing their list/index representations or
adding an alternate import path. Follow-up review made missing, unique, and
ambiguous module identity resolution explicit and routed both normal and traced
production typechecking through the shared visible/direct selection helpers.
Checkpoint B owns the broader module-view data-model transition.

Before integrating the next main commit, validation passed 206 focused
import/declaration/bridge/benchmark tests, 1,504 compiler tests, 562
compiler-unit tests, and 3,308 compiler-deep tests. After fast-forwarding to
`65e33a78723113e74bc870bf33bfc0d3655296cc`, which made compiler metadata states
more precise, the build, 205 conflict-sensitive focused tests, all 2,066
compiler-unit/compiler tests, and 192 focused sanitizer tests passed. The one
fewer focused test is main's intentional removal of a test that manually
constructed an invalid value-slot state. The build-configuration contract,
formatting, `git diff --check`, and generated-C artifact scan were clean.
Independent review found no remaining checkpoint issues after explicit identity
resolution and shared production selection were added.

Nine cooled warm post-separation samples on integrated compiler revision
`65e33a` had a 63,086 microsecond elapsed median and an 18,615 microsecond setup
median, compared with the 63,397 and 18,389 microsecond preparation baseline.
Elapsed changed by roughly -0.5% and setup by +1.2%; every logical workload
counter remained identical, so no performance change is attributed to this
mechanical checkpoint. The samples are retained in
`benchmarks/results/compiler_module_binding_phase2_checkpoint_a_2026-08-04.tsv`.

### Checkpoint B: Phase Types

Introduce:

```text
CompilerBoundModuleGraph
CompilerModuleView
CompilerImportBinding
CompilerVisibleDefinition
```

A module view belongs to one canonical module identity and describes exactly
which graph definitions are available under which local source names. It does
not contain copied semantic declarations. Public constructors must not allow a
private definition to be inserted as a visible export.

The view owns both deterministic source order and keyed lookup. Callers cannot
construct or independently update parallel `imported_names` and
`imported_names_by_local_name` representations. Existing exact-path,
imported-name, and top-level-name indexes move behind this boundary; they are
not discarded during migration. Module aliases and selective names are distinct
binding variants so the absence of an `original_name` is represented by the
binding kind rather than an optional field with an implicit invariant.

Qualified imports, selective imports, renamed symbols, prelude injection,
ambient implementations, package origins, and unused-import tracking remain
explicit facts. The same module view must resolve trait names used by
`implements`, including selective aliases; implementation validation and
default-body materialization must not perform a second original-name lookup in
the broad environment.

### Checkpoint C: Parity

Cover duplicate modules and aliases, missing modules and symbols, private
exports, qualified/selective imports, same-name modules, packages, stdlib
restrictions, prelude behavior, import cycles, aliased imported traits used by
implementations, and exact diagnostic ownership.

### Checkpoint D: Simple Optimization

Index modules by canonical path and visible bindings by local name. Compute each
module's direct imports and reachable type dependency closure once. Preserve
deterministic source order separately for diagnostics. Replace the Phase 1B3
batch-local exact-path index with one graph-owned canonical/alias index. Alias
entries must retain every matching canonical module so ambiguity diagnostics
remain sorted and order-independent without rescanning all modules.

### Benchmark

Use `compiler_module_binding_profile` as the fast binding loop. Its logical
counts cover exact and alternate-name probes, accepted aliases/selective names,
binding insertions, exported symbols, and baseline candidate/surface scan
pressure. It also reports the exact baseline list comparisons performed by
import-binding deduplication. Pair these stable logical counts with elapsed and
inclusive function time; semantic lookup call counts need not fall when an
index removes comparisons. Do not add permanent benchmark counters to
production state merely to measure an implementation detail.

Keep `compiler_import_graph_profile` as the end-to-end parity control and add a
separate closure-focused mode before changing dependency-closure construction.
That mode must use the production closure operation on prepared graph modules,
exclude parsing and body inference, and validate closure membership and order in
addition to counting root edges and reachable-module visits.

### Exit Criteria

- module views contain identity and visibility, not parsed declarations;
- semantic header phases consume definition IDs selected by a module view;
- aliases remain module-local; and
- the old import-registration selection path is deleted.

## Phase 3: Type Header Graph

### Goal

Resolve canonical type declarations once before callable, trait, and body
checking.

### Current Responsibility

Reachable modules currently replay record, union, builtin/resource type, alias,
constructor, type-home, and containment registration into each module state.

### Checkpoint A: Mechanical Separation

Move type prescan, canonical type naming, type declaration registration, type
home, alias, constructor, resource cleanup, and containment-header helpers under
`stage_06_typecheck/headers/`. First call them through the existing module-state
path.

### Checkpoint B: Phase Types

Introduce `CompilerTypeHeaderGraph`, built only from
`CompilerBoundModuleGraph`. It owns canonical type definitions and graph indexes
by stable type identity. Keep module-local nameability in `CompilerModuleView`.

Represent transparent alias, opaque alias, record, union, builtin type, resource
type, and constructor facts with precise variants. Do not use Boolean
combinations to distinguish their layout or visibility.

Private types may remain semantic dependencies of legal public signatures
without becoming nameable imports. Characterize and test that rule before
rejecting or exporting such shapes.

### Checkpoint C: Parity

Cover recursive records/unions, cyclic aliases, generic types, duplicate names
across modules, constructors, opaque aliases, resource containment and cleanup,
qualified names, package/std restrictions, and type diagnostics.

### Checkpoint D: Simple Optimization

Resolve each type declaration once per defining module. Reuse canonical type
headers and containment summaries across importers. Bulk-install or directly
reference type headers; do not reconstruct `CompilerType` from parsed type
expressions on import edges.

### Benchmark

Add a type-heavy import graph varying type declarations, nesting depth, alias
depth, and fan-out. Count semantic type resolutions, containment computations,
constructor registrations, and importer installations.

### Exit Criteria

- semantic type-resolution count scales with declarations, not import edges;
- no unrelated canonical type becomes available under a bare name;
- the completed type-header graph is required by later header phases; and
- parsed imported-type registration is deleted.

## Phase 4: Callable And Declared-Value Headers

### Goal

Resolve callable signatures and explicitly declared global types once per
defining declaration. Represent unannotated globals as pending initializer work
rather than pretending their type is already known.

### Current Responsibility

Local and imported function registration currently resolves annotations,
generic bounds, purity, resource policies, dimension constraints, loop-producer
metadata, debug-only status, origins, parameter names, and callable IDs while
mutating a general environment. Imported declarations repeat that work for each
direct import edge. Global declarations with annotations have resolvable header
types, while unannotated globals acquire their binding type only when their
initializer is inferred.

### Checkpoint A: Mechanical Separation

Extract declaration-to-semantic-signature resolution from environment mutation.
Use the same resolver for local and imported declarations before changing
production ownership. Move function, foreign-function, declared-global, and
pending-global header logic under `headers/`.

### Checkpoint B: Phase Types

Introduce precise header variants such as:

```text
CompilerUserCallableHeader
CompilerForeignCallableHeader
CompilerDeclaredGlobalHeader
CompilerPendingGlobalInitializer
```

Each callable header includes one graph-assigned definition ID, owner module,
canonical semantic type, generic bounds, parameter metadata, purity, resource
policy, dimension constraints, and relevant annotations. Smart constructors
enforce origin and visibility; avoid a contradictory `is_foreign` Boolean.

A declared global header contains its canonical declared type. A pending global
contains its definition ID, owner, source declaration identity, initializer
identity, mutability, and ordering facts, but no fabricated semantic type. Do
not represent a pending global as `CompilerGlobalValueHeader` with `Void`, an
optional semantic type, or a `type_inferred` Boolean.

Produce `CompilerCallableHeaderGraph`. Callable and declared-global headers
contain no body or initializer expression. A pending global may reference its
initializer by stable parsed-body identity; it must not be usable as a completed
value header.

### Checkpoint C: Parity

Cover overloads, recursive and cyclic function imports, generics and shadowing,
return-only parameters, callbacks, qualified annotations, resources, dimensions,
purity, debug-only functions, loop producers, annotated and unannotated globals,
foreign restrictions, private declarations, and exact call targets in typed
AST.

### Checkpoint D: Simple Optimization

Resolve each public callable and declared-global signature once in its defining
module and let importers reference or bulk-install the resolved header. Resolve
private/local-only headers once for their owner. Carry pending globals forward
without guessing their types. Delete the imported parsed-signature path.

### Benchmark

Use the existing import-heavy graph. Required counters include public callable
headers, semantic signature resolutions, cheap visibility installations, and
parsed imported-signature resolutions. The final counter must become zero.

### Exit Criteria

- signature resolution count equals declaration count independent of fan-out;
- cycles do not require body order;
- imported diagnostics belong to the defining module when appropriate;
- CTFE and initializer inference use the same callable headers;
- a pending global cannot be looked up as a typed value; and
- the import-heavy benchmark improves clearly without a material low-import
  regression.

## Phase 5: Trait And Implementation Headers

### Goal

Give traits, methods, bounds, implementations, and UFCS candidates stable
semantic identity and indexed ownership.

### Current Responsibility

Traits, implementations, overload sets, and UFCS methods are stored in several
lists inside `Env`. Obligation solving and conflict checks scan broad
implementation lists and rely heavily on string trait names and structural type
matching.

### Checkpoint A: Mechanical Separation

Move trait declaration registration, method headers, supertrait validation,
implementation registration, overlap checks, obligation candidate collection,
and UFCS candidate collection under `headers/` or a focused trait subdirectory.
Preserve the current solver and diagnostics initially.

### Checkpoint B: Phase Types

Introduce stable trait and implementation identities, precise trait/method/
implementation headers, and an immutable `CompilerTraitIndex` owned by
`CompilerDeclarationHeaderGraph`.

Represent candidate lookup separately from candidate proof. A lookup may return
several candidates; only the solver decides satisfaction, ambiguity, or
deferral. Keep private implementation visibility and ambient implementation
rules explicit in module views.

### Checkpoint C: Parity

Cover supertraits, blanket and concrete implementations, overlap, orphan/private
rules, default methods, imported implementations, generic bounds, deferred meta
obligations, UFCS, overload ranking, arrays' builtin evidence, and ambiguity
diagnostics.

### Checkpoint D: Simple Optimization

Index implementation candidates by stable trait identity and conservative
receiver-type head. Index UFCS candidates by source method name and receiver
head. A head index may return a superset, but it must never exclude a legal
candidate; the existing semantic matcher remains authoritative.

### Benchmark

Add a trait-heavy fixture varying unrelated traits, implementations per trait,
receiver heads, generic candidates, and UFCS calls. Count candidates visited,
structural matches, bound checks, and full-list scans.

### Exit Criteria

- body checking reads immutable trait facts from the header graph;
- candidate work scales with relevant buckets rather than all implementations;
- no string/path heuristic establishes trait identity; and
- imported parsed trait/implementation registration is deleted.

## Phase 6: Global Initializer Typing And Header Completion

### Goal

Infer each unannotated global's binding type exactly once and produce the
completed `CompilerHeaderGraph` required by ordinary body checking. Keep type
inference separate from CTFE value evaluation.

### Current Responsibility

Global prescan currently registers an unannotated local global using a fallback
type and materialization later replaces that binding with the initializer's
inferred type. Imported globals without source annotations also receive a
fallback. This allows a partially known value binding to inhabit the same
environment representation as a completed value header.

Global initializers have deliberate ordering rules: earlier compile-time
constants may be referenced, later constants and self-references are rejected,
and mutable startup expressions have additional restrictions. Initializer type
inference may use callable signatures, but CTFE evaluation of a called function
requires its typed body later.

### Checkpoint A: Mechanical Separation

Move global type expectation, initializer inference entry, declaration-order
checks, inferred binding registration, mutable-startup validation, and typed
global construction into a focused header-completion module. Initially call the
existing inference engine and preserve current ordering and diagnostics.

Keep CTFE evaluation in graph assembly. This phase determines semantic binding
types and initializer typed bodies; it does not execute constants.

### Checkpoint B: Phase Types

Introduce precise variants such as:

```text
CompilerDeclaredGlobalHeader
CompilerPendingGlobalInitializer
CompilerResolvedGlobalHeader
CompilerRejectedGlobalHeader
```

Consume `CompilerDeclarationHeaderGraph` and produce `CompilerHeaderGraph` plus
module-owned diagnostics. Every usable global in the completed graph has a real
semantic type. A rejected initializer remains a recoverable diagnostic artifact
and cannot masquerade as a valid value header.

Represent initializer dependencies by stable definition identity. Do not use a
`Void` type, missing type, or source-name lookup as a dependency or failure
sentinel.

### Checkpoint C: Parity

Cover annotated and inferred globals, mutable globals, self-reference, forward
reference, earlier constant reference, pure function calls, impure calls,
lambdas, collections, resources, dimensions, imported globals, private globals,
and global constants participating in CTFE.

Characterize cross-module and cyclic dependencies before changing them.
Annotated globals can be cycle-safe at the header level. Inferred global cycles
must either be resolved by an explicit deterministic rule or rejected early
with a tested diagnostic; they must never become `Void` by accident.

### Checkpoint D: Simple Optimization

Infer each initializer once, update the completed global-header index directly,
and share the resulting type with importers and CTFE. Avoid registering a
placeholder and later rebuilding importer environments.

### Benchmark

Use modules with many annotated and inferred globals, ordered dependencies,
initializer calls, and import fan-out. Count initializer inference runs,
placeholder registrations, inferred-header updates, dependency lookups, and
imported global installations.

### Exit Criteria

- ordinary body checking receives only completed global value headers;
- unannotated global types are inferred once per defining declaration;
- source-order and dependency diagnostics are deterministic;
- no `Void` or optional type represents a pending global; and
- CTFE receives typed initializers without re-running type inference.

## Phase 7: Body Context And Inference Session

### Goal

Make each function, method, and initializer body independently checkable against
read-only graph facts.

### Current Responsibility

`CompilerTypecheckState`, `Context`, and `Env` mix graph,
module, function, and inference state. Body materialization loops sequentially
over declarations and carries the resulting broad state into the next body.

### Checkpoint A: Mechanical Separation

Introduce a `body/` directory and move body setup, parameter binding, local
scope operations, expected-return setup, body materialization, and inference
entry/exit helpers in small slices.

Because `compiler_infer.brp` is large, split it mechanically by cohesive
responsibility over separate mergeable changes:

1. inference result/context and dispatch;
2. names, literals, bindings, assignments, and aggregates;
3. calls, overloads, traits, UFCS, and callbacks;
4. patterns, match, control flow, loops, and propagation;
5. resources, `with`, streams, concurrency, and channels;
6. tensors, dimensions, ranges, subscripts, and refinements; and
7. typed-expression traversal and finalization helpers.

Do not force a cyclic module split. Move shared data types downward first, keep
dispatch in one owner, and combine two proposed files when their APIs would
otherwise be mutually recursive.

### Checkpoint B: Phase Types

Introduce:

```text
CompilerBodyCheckContext   -- immutable header graph + module view + body header
CompilerInferSession       -- local scopes, metas, substitutions, local errors
CompilerInferredBody       -- typed shape may still contain local metas
```

`CompilerInferSession` must not expose graph-mutating operations. Local IDs,
metavariables, and resource scope IDs belong to the body and cannot collide with
another body.

### Checkpoint C: Parity

Characterize every expression family before moving it. Preserve source spans,
expected-type propagation, call identity, overload behavior, diagnostics order,
resource scope, dimensions, refinements, and typed-expression metadata.

Add a deterministic test that checks the same set of bodies in different
orders and receives identical per-body output and sorted module diagnostics.
This proves independence without enabling parallel execution yet.

### Checkpoint D: Simple Optimization

Remove general-state copying and graph/environment rebuilding at body entry.
Keep lexical name indexes local. Reuse read-only header references rather than
copying semantic symbols into every body session.

### Benchmark

Use low-import modules with many independent bodies and variants for small,
large, generic, resource-heavy, and call-heavy functions. Count body-context
construction, semantic graph copies, local symbol insertions/lookups, and bytes
or allocations where instrumentation permits.

### Exit Criteria

- a body can be checked from one immutable context and one fresh local session;
- checking order does not affect IDs, types, or diagnostics;
- no completed body mutates module or graph semantic facts; and
- the old broad body-entry state API is deleted.

## Phase 8: Constraint Solving And Type Finalization

### Goal

Separate expression inference from the guarantee that no inference-only type
state escapes into the completed typed body.

### Current Responsibility

`CompilerMetaType(Int)` values share the recursive `CompilerType` union with
stable semantic types. Metavariable origins and bindings live in lists inside
`Context`; lookup scans the list and binding rebuilds it. Finalization
and meta detection traverse typed expressions after inference.

### Checkpoint A: Mechanical Separation

Move fresh-meta creation, occurs checks, unification, dimension-meta handoff,
resolution, zonking/finalization, and unresolved-meta diagnostics into focused
body solver modules. Preserve the current type representation and algorithms.

### Checkpoint B: Phase Types

Introduce `CompilerSolvedBody`, constructible only by the solver/finalizer.
Its constructor verifies that no body-local metavariable remains in semantic
types, resolved call metadata, value slots, proofs, resource facts, or nested
typed expressions.

Use distinct opaque `CompilerMetaId` and stable semantic IDs where practical.
Do not let a raw `Int` from another domain be accepted as a metavariable ID.

### Checkpoint C: Parity

Cover occurs checks, unresolved parameters, recursive generic calls, overload
deferral, callback inference, return-only generics, tensor dimensions, symbolic
ranges, aliases, resources, and diagnostics that depend on meta origin names.

### Checkpoint D: Simple Optimization

Replace linear metavariable lookup/replacement with a dense body-local table or
another exact indexed structure. Add path compression or union-find only if the
Blorp value-semantics implementation remains simple and measurements justify
it. Ensure uniquely owned local updates are an optimization, not a correctness
precondition.

Avoid repeated whole-body zonking. Resolve each necessary type at the narrowest
boundary and perform one final invariant traversal.

### Benchmark

Use generic and dimension-heavy bodies with controlled numbers of metas,
bindings, unifications, occurs checks, and typed nodes. Count binding probes,
binding updates, recursive type visits, and finalization traversals.

### Exit Criteria

- downstream validators cannot receive a body containing metas;
- meta operations are body-local and indexed;
- diagnostics retain useful source origins; and
- current generic, refinement, and dimension behavior is unchanged.

## Phase 9: Semantic Body Validation

### Goal

Turn purity, resource, match, tail-recursion, debug, and related body rules into
explicit validation responsibilities over solved bodies.

### Current Responsibility

Some rules are checked during inference, while others recursively rescan the
typed body after inference. Purity alone collects impure calls, module
assignments, nested pure-lambda violations, and debug-block violations through
separate traversals. Resource escape requires lexical information and must not
be naively postponed.

### Checkpoint A: Mechanical Separation

Move each rule and its typed-expression traversal into `validation/` without
changing when it runs. Establish one owner for:

- explicit purity and callback-purity validation;
- debug-block restrictions;
- module assignment restrictions;
- match exhaustiveness and related pattern validation;
- tail-recursion validation;
- resource binding, dependency, and escape validation;
- concurrency capture and body restrictions; and
- final typed-body invariants.

### Checkpoint B: Phase Types

Introduce explicit per-rule facts and a `CompilerValidatedBody` success type.
Keep resource scope checks that require lexical structure in inference, but
record stable `CompilerResourceScopeId`/`CompilerLocalId` facts rather than
string owner names. The final resource validator confirms that no scoped or
derived value escapes.

Purity is explicit in Blorp signatures, so ordinary compilation does not need a
global purity fixed point. Inference should record call/effect facts and the
validator should check them once against the declared purity.

### Checkpoint C: Parity

Compare exact diagnostics for pure calls and callbacks, module assignments,
debug blocks, nested lambdas, all match forms, tail calls, `with` escape,
resource-derived values, loops/closures, channels, and concurrency captures.

Prove that a rejected body cannot be passed as a validated body and that
recoverable typed output remains available for diagnostics and tools.

### Checkpoint D: Simple Optimization

Collect validation facts during the main typed-expression traversal or during
inference, then eliminate redundant whole-tree scans. Combine traversals only
when ownership remains clear; do not create one untyped bag of unrelated flags.

### Benchmark

Use large nested bodies with controlled counts of calls, lambdas, matches,
resources, and control-flow nodes. Count typed-node visits per validator and
total validation traversals.

### Exit Criteria

- accepted and rejected body outcomes are distinct;
- validators consume solved bodies and stable identities;
- local resource safety remains checked at the earliest valid point;
- ordinary purity validation is one pass over explicit facts; and
- no redundant typed-body scan remains without measured justification.

## Phase 10: Typed Graph Assembly And CTFE

### Goal

Assemble completed module artifacts and CTFE values without re-typechecking or
reconstructing semantic headers.

### Current Responsibility

The bridge prepares CTFE dependency order, typechecks CTFE dependencies,
sometimes reuses their typed programs, typechecks selected graph modules, and
constructs `CompilerTypecheckedModule`/`CompilerTypecheckedGraph` artifacts.
This orchestration is interleaved with parsing, importable-module creation,
definition planning, tracing, inventory, and JSON streaming.

### Checkpoint A: Mechanical Separation

Move typed-module construction, CTFE dependency scheduling, typed CTFE artifact
reuse, selected-module assembly, diagnostics aggregation, and graph inventory
under `assembly/`. Keep bridge request decoding and response streaming outside.

### Checkpoint B: Phase Types

Introduce `CompilerTypedGraph` as the only successful input to Core lowering.
It contains completed header identity, accepted/recoverable body outcomes,
module-owned diagnostics, import bindings, and CTFE artifacts with explicit
status.

Represent fresh typed body, reused typed CTFE body, evaluated constant, failed
CTFE dependency, and non-CTFE module with precise variants rather than coupled
Boolean fields.

### Checkpoint C: Parity

Cover CTFE dependency order and cycles, selected/unselected modules, failed
dependencies, globals, typed-program ownership, comments, inventory, exact
diagnostics, Core lowering, and deterministic module output order.

### Checkpoint D: Simple Optimization

Guarantee that each required body is typechecked at most once per graph and that
CTFE consumers reuse the same header and typed-body artifacts. Pre-index
artifacts by module/definition identity while retaining deterministic source
order for output.

After body independence is proven, run a separate design and benchmark slice
for parallel body checking. Parallelism is accepted only when diagnostics,
resource ownership, memory use, and low-core-count performance remain
predictable.

### Benchmark

Use graphs with overlapping CTFE and output-module dependencies. Count body
checks, header uses, CTFE evaluations, reused typed artifacts, module scans, and
peak memory.

### Exit Criteria

- Core accepts only the completed typed-graph phase product;
- no module body is checked twice for CTFE and output;
- bridge code only orchestrates protocol and phase calls;
- graph diagnostics are deterministic; and
- phase-level production and benchmark paths are identical.

## Benchmark Matrix

Each phase owns one fast fixture and may share an acceptance fixture.

| Phase | Fast workload | Primary counters |
| --- | --- | --- |
| Identity | declaration-heavy small graph | reservations, exact lookups, index builds |
| Module views | high fan-out, tiny exports | path probes, closure visits, binding inserts |
| Type headers | nested types and aliases | type resolutions, containment scans, installations |
| Callable headers | import-heavy function graph | signature resolutions, cheap installations |
| Traits/impls | many unrelated candidates | candidate visits, matches, bound checks |
| Globals | inferred and declared initializers | inference runs, dependency probes, header updates |
| Body context | many independent bodies | context builds, graph copies, local lookups |
| Solver | generic/dimension-heavy body | meta probes, binds, occurs checks, zonk visits |
| Validation | large nested typed body | node visits and validator passes |
| Assembly/CTFE | overlapping dependency graph | body checks, CTFE evaluations, artifact reuse |

### Measurement Rules

1. Use the same bootstrap compiler, C compiler, flags, fixture, and worker for
   baseline and candidate.
2. Warm up before recording samples.
3. Alternate baseline and candidate runs when machine drift is material.
4. Store raw samples, median, range, checksum, revision, and machine/toolchain
   metadata.
5. Treat function-profile rows as inclusive unless the profiler says otherwise.
6. Do not claim a speedup from operation counts alone; use counts to explain
   stable timing or expose scaling.
7. Reject timing-only optimizations inside normal run-to-run noise.
8. A local optimization should not regress a representative low-import or
   low-generic workload by more than 3% without a documented broader win.
9. Memory is part of acceptance when sharing or retaining graph facts changes.
10. Benchmark code must not become a second production implementation.

## Test Strategy

### Characterization Before Movement

Before mechanically moving a responsibility, identify the existing focused
tests and add only missing characterization. Do not rewrite tests to mirror the
new implementation before parity is established.

### Phase Construction Tests

For every opaque phase type, test:

- valid construction;
- invalid or contradictory input;
- deterministic identity and ordering;
- ownership under shared and unique use;
- absence of inappropriate earlier-phase data; and
- inability of downstream APIs to accept the previous phase type.

### Semantic Matrix

Retain coverage across:

- qualified, selective, aliased, cyclic, package, stdlib, and private imports;
- records, unions, structs, aliases, opaque types, resources, and constructors;
- globals, functions, foreign functions, overloads, generics, and callbacks;
- traits, supertraits, implementations, defaults, ambiguity, and UFCS;
- Option/Result propagation, lambdas, closures, loops, matches, and assignment;
- tensor dimensions, ranges, refinements, and subscripts;
- purity, debug restrictions, resources, concurrency, and channels;
- CTFE, typed artifacts, Core lowering, and generated C; and
- error recovery, source spans, diagnostic text, and deterministic order.

### Validation Gates

The exact gate scales with the checkpoint, but a production cutover should run:

```bash
make
scripts/test compiler-unit
scripts/test compiler-unit-deep
scripts/test compiler
scripts/test compiler-deep
scripts/test compiler-blorp-sanitize
scripts/test std-check
scripts/test runtime
scripts/test leak
make quality
git diff --check
```

Use focused tests during development. Run broader gates before declaring the
checkpoint mergeable. Inspect typed artifacts, Core, or generated C when the
changed phase owns facts visible there.

## Mergeability Contract

Every checkpoint merged to main must satisfy all of these:

1. Production uses one authoritative path for the moved responsibility.
2. No feature flag selects old versus new typechecking architecture.
3. Temporary adapters have a documented deletion checkpoint and no semantic
   duplication.
4. Tests pass at the scope required by the changed boundary.
5. Diagnostics and typed output are unchanged unless the checkpoint explicitly
   fixes a tested bug.
6. Benchmarks remain runnable and checksummed.
7. No generated artifacts or unexplained formatting churn remain.
8. Architecture and roadmap status match production.
9. The branch can be stopped after the checkpoint without leaving main in a
   conceptually half-migrated state.

Prefer several small commits that are each reviewable over one commit combining
movement, representation, behavior, and optimization. Squashing for merge is a
repository decision; the development history should still make those concerns
separable during review.

## Stop And Rollback Rules

Stop and narrow or revert a checkpoint when:

- a mechanical move changes semantics or diagnostics unexpectedly;
- a phase type needs optional later-phase fields or validity Booleans;
- production must retain two semantic implementations indefinitely;
- cyclic imports become order-dependent;
- stable IDs change without an explicit language/compiler reason;
- visibility depends on a source-name or path heuristic not represented in a
  module view;
- a shared graph value must be uniquely owned for correctness;
- an optimization improves only its microbenchmark while materially regressing
  representative compilation;
- a benchmark cannot distinguish less work from changed workload; or
- the branch cannot be merged until several unrelated phases are complete.

Useful tests, traces, counters, and benchmark improvements may be retained
separately from a rejected architectural experiment.

## Post-Decomposition Optimization Review

After all phase boundaries are in production, re-profile before selecting more
work. Consider these opportunities in measured order:

1. **Interned stable semantic types.** Replace repeated recursive stable type
   values with `CompilerTypeId` only after type-header ownership is settled.
   Keep body-local inference variables separate from interned types.
2. **Dense or union-find inference storage.** Broaden the Phase 8 local table if
   real bodies still spend material time resolving meta chains.
3. **Parallel body checking.** Use immutable header graphs and isolated sessions;
   aggregate diagnostics deterministically and cap concurrency explicitly.
4. **Incremental compilation.** Consider only after phases expose explicit
   dependencies and deterministic products. This roadmap adds no cache.
5. **More precise trait indexing.** Add secondary indexes only when candidate
   counts remain material after trait/head bucketing.
6. **Structured diagnostics.** Replace rendered strings at phase boundaries
   before the remaining LSP/tool migration needs semantic diagnostics.
7. **Typed AST compaction.** Measure repeated type and call metadata after type
   interning; do not remove facts Core or tooling consumes.
8. **Arena-like local storage.** Consider body-local allocation strategies only
   after reducing construction and traversal counts.
9. **Cross-body shared generic work.** Specialization or canonical-instantiation
   reuse requires explicit identity and should not become hidden caching.
10. **Bridge deletion.** Remove serialization and helper-process overhead through
    the compiler-port roadmap rather than optimizing protocol payloads forever.

## First Mergeable Slice (Completed 2026-08-02)

Begin with Phase 0 and Phase 1A only. Do not introduce the entire phase graph in
the first implementation branch.

The first production change should:

1. identify or add focused tests for graph definition-ID reservation order,
   overloads, constructors, traits, implementations, foreign functions, and
   default methods;
2. record the fast declaration-index benchmark baseline and its checksum;
3. create `stage_06_typecheck/graph/` with one module owning the existing
   definition-plan records and reservation traversal;
4. make `compiler_typecheck_bridge.brp` call that module without changing the
   plan's representation, ID order, or downstream state injection;
5. keep the production and benchmark callers on the same extracted function;
6. run focused tests, compiler tests, formatting, and `git diff --check`; and
7. merge before introducing `CompilerIndexedGraph` in Phase 1B.

This slice is intentionally mechanical. Its value is a small, authoritative
ownership boundary and an easier next change, not an immediate speedup.

## Definition Of Done

This roadmap is complete when:

1. The production path exposes explicit indexed, bound-module, header, inferred,
   solved, validated, and typed-graph phase products or equally precise types.
2. Graph-wide semantic declarations are resolved once per defining module.
3. Import edges perform binding and visibility work but no parsed-to-semantic
   declaration reconstruction.
4. Every usable global header has a real declared or inferred type; pending and
   rejected initializers are distinct states.
5. Body checks use immutable graph/module context and isolated inference state.
6. No inference metavariable can escape a solved body.
7. No rejected or partially checked body can be passed as validated.
8. Trait and UFCS lookup use explicit identities and conservative indexes.
9. Purity and resource rules remain sound without redundant whole-body scans.
10. CTFE and ordinary output reuse the same headers and typed bodies.
11. Typechecking order does not affect IDs, diagnostics, or typed output.
12. Every phase has a fast deterministic benchmark and durable acceptance data.
13. The old broad registration/state paths and transitional adapters are
    deleted.
14. Architecture documentation names the actual production phase owners.
15. Compiler, deep, sanitizer, leak, format, quality, and representative
    benchmark gates pass.
