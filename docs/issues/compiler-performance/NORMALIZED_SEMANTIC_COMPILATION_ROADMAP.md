# Normalized Semantic Compilation Roadmap

**Status:** Step 1 implemented and measured; Step 2 is next. The completed
module and definition identity work is the foundation; this roadmap defines
the next finite checkpoint.

**Scope:** One compiler invocation and one immutable analysis snapshot. This
roadmap makes accepted and recoverable semantic facts directly queryable by the
compiler, diagnostics, lint, LSP, profiling attribution, and inspection tools.
It does not define a cross-run cache, an incremental build database, a generic
query engine, or an immediate rewrite of every syntax and Core expression tree.

**Parent architecture:**
[`NORMALIZED_COMPILATION_DATABASE_ROADMAP.md`](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)
owns the long-term table, identity, lifetime, and migration invariants. This
document owns the execution order and acceptance gates for the normalized
semantic compilation checkpoint. If the two documents appear to disagree,
preserve the parent's invariants and update this execution plan after a current
production audit.

**Typechecking coordination:**
[`docs/COMPILER_PRIORITIES.md`](../../COMPILER_PRIORITIES.md) and its Phase 8-10
issues own inferred/solved/validated body semantics and the checked/codegen-ready
graph boundary. This roadmap must consume those products; it must not create a
parallel typechecker or label the current broad graph as a new accepted product.

## Executive Decision

Blorp has normalized semantic identity further than it has normalized semantic
facts. `ModuleId`, `DefinitionId`, and category-safe identities now provide a
credible primary-key spine, but important relationships and accepted outcomes
are still reconstructed from rich `TypedProgram` trees, string-keyed module
views, and the broad `TypecheckedGraph` compatibility product.

The next architectural commitment is:

> Once a compiler phase publishes an authoritative semantic row or edge, no
> downstream phase or tool may rediscover that fact from a name, path, source
> shape, nested typed tree, or independently rebuilt dictionary.

This is not a rule that every value must become an integer. Expression trees
may remain trees when they provide better locality and simpler transformations.
The rule applies to stable entities, ownership, acceptance state, and relations
that multiple consumers need to query.

The checkpoint is complete when the compiler publishes distinct recoverable,
accepted, and codegen-ready semantic products; semantic consumers use exact
tables and edges; the old reconstruction paths are deleted; and the combined
checkpoint improves most measured resource metrics without a material
regression in any guard metric.

## Why This Precedes The Tooling Roadmap

The desired developer tools are queries over semantic facts:

| Tooling question | Required authoritative facts |
| --- | --- |
| What does this name mean here? | visibility, shadowing, import, and definition relations |
| Why did this call resolve here? | exact candidates, selected callable/implementation, and rejection provenance |
| Where is this symbol used? | definition and reference occurrences keyed by exact identity |
| What depends on this change? | call, global-reference, type-use, and import edges |
| Which error is the root cause? | diagnostic ownership, related spans, and causal relations |
| What should completion show? | request-position value/type namespaces and exact precedence |
| What did this profile row execute? | definition identity and explicit emitted-symbol projection |
| Which tests should run? | source/module/definition ownership and declared test relations |

Without a shared semantic product, each tool must walk large trees, duplicate
resolution rules, or infer relationships from display strings. That creates
semantic drift, repeated work, larger context, and weak diagnostics. A normalized
semantic product lets tools share one compiler-owned answer while retaining
narrow capability-specific APIs.

## Current Production Boundary

The completed identity checkpoint provides:

- one Stage 04 `ModuleTable` and graph-local `ModuleId` domain;
- one Stage 06 `DefinitionTable` with deterministic, append-only graph rows;
- scalar definition-backed callable, nominal type, global, field, trait, and
  implementation identities;
- category-specific accepted tables and provenance checks; and
- retained module/definition authorities through CTFE and Core graph entry.

The remaining split authorities are concrete:

- `TypecheckedModule` retains parsed source, a source-faithful semantic program,
  a CTFE-rewritten typed program, errors, diagnostics, imports, and a CTFE
  Boolean in one record.
- `TypecheckedGraph` retains the module and definition tables beside rich module
  payloads, but it does not publish the accepted category, body-outcome,
  visibility, occurrence, and diagnostic tables as one coherent product.
- `ModuleView` owns string-keyed aliases, imports, local names, and nested
  accepted authorities. These are useful lookup structures, but they are not
  yet one canonical visibility relation.
- semantic definitions and references are projected for LSP by walking complete
  typed programs after typechecking.
- CTFE uses exact identities for important paths but still materializes and
  rewrites complete typed programs at compatibility boundaries.
- Core graph preparation still accepts `CoreGraphUnit { module_id,
  typed_program }`, constructs display/C-oriented names, and flattens modules
  into one nested `CoreProgram`.

The roadmap treats those as migration boundaries, not permission to add a
second database alongside them.

## Target Product Model

The names below are design examples, not pre-approved public API names. Each
implementation issue must check local precedent and choose precise names.

```blorp
private record SemanticCatalogRep {
	module_table: ModuleTable,
	definition_table: DefinitionTable,
	types: AcceptedTypeTable,
	callables: AcceptedCallableTable,
	globals: AcceptedGlobalTable,
	constructors: AcceptedConstructorTable,
	fields: AcceptedFieldTable,
	traits_and_implementations: AcceptedTraitImplementationTable
}

opaque type SemanticCatalog = SemanticCatalogRep
```

The catalog owns accepted entity facts. Relations remain separate tables so an
entity row is not copied for each importer, reference, call, or containment
edge.

```blorp
record VisibleBindingRow {
	viewer_module: ModuleId,
	namespace: SemanticNamespace,
	local_name: String,
	entity: VisibleSemanticEntity,
	origin: VisibilityOrigin,
	order: VisibilityOrder
}

record SemanticReferenceRow {
	owner: SemanticOccurrenceOwner,
	target: SemanticEntityId,
	span: SourceSpan,
	kind: SemanticReferenceKind
}
```

Acceptance is represented by product type, not a Boolean or empty error list:

```blorp
union SemanticCompilationOutcome:
	SemanticCompilationAccepted(AcceptedSemanticCompilation)
	SemanticCompilationRejected(RecoverableSemanticCompilation)

opaque type CodegenReadyCompilation = CodegenReadyCompilationRep
```

The recoverable product may retain rejected declarations and diagnostics for
`check`, lint, and LSP. Only accepted tables can construct the codegen-ready
product. Core lowering must not accept the recoverable form or a raw
`TypedProgram`.

## Product And Lifetime Rules

1. **One issuer per identity domain.** An ID is meaningful only with the table
   that issued it. Products that exchange IDs must prove compatible provenance.
2. **One authority per fact.** An index or view may accelerate a query, but its
   rows validate against one canonical entity or edge table.
3. **Append privately, publish immutably.** Builders own unique COW storage until
   validation and publication. Published rows never change meaning or number.
4. **Accepted and rejected facts are distinct.** Recovery information cannot
   inhabit an accepted category table merely because a status flag is false.
5. **Trees remain legitimate payloads.** Parsed, typed, and Core expression
   trees are not flattened until measurements show a real win.
6. **Retain only for a named consumer.** Compile-only, analysis, lint, and LSP
   modes select explicit products. A universal snapshot must not retain every
   syntax, typed, CTFE, and Core payload until emission.
7. **Materialize strings at boundaries.** Paths, display types, error text,
   protocol values, and C symbols are projections, not internal join keys when
   typed IDs exist.
8. **Record derivation where explanation requires it.** Final semantic edges
   answer what resolved. Optional bounded provenance tables answer why without
   forcing every ordinary compilation to retain full solver traces.
9. **Delete migrated paths in the same issue.** A new table beside the complete
   old authority is an experiment, not an acceptable merged endpoint.
10. **Fail closed.** Foreign-key, ordering, provenance, duplicate, and accepted
    state validation happens before an opaque product is published.

## Performance And Evidence Contract

Normalization is expected to improve compiler and tooling efficiency, not only
architecture. An individual enabling slice may be neutral within measurement
noise, but the combined checkpoint must improve most applicable metrics and no
guard metric may regress materially.

### Correctness gates

Every measured baseline/candidate pair requires:

- identical accepted/rejected outcomes;
- identical module, definition, and generated-definition allocation order;
- identical semantic checksums and exact resolved identities;
- identical diagnostic ordering and human text until a diagnostic issue
  explicitly changes the public rendering;
- byte-identical replay responses for representation-only changes;
- byte-identical generated C unless the issue explicitly changes a backend
  projection, followed by equivalent runtime output and audited C; and
- deterministic LSP JSON ordering and exact completeness/partial-coverage
  behavior.

Any semantic mismatch invalidates the performance sample.

### Resource scorecard

Each issue records baseline, candidate, delta, confidence/noise assessment, and
raw evidence for the applicable rows:

| Metric | Scope |
| --- | --- |
| Compiler latency | focused phase, target-only replay, and full replay p50/p95 |
| Tooling query cost | snapshot construction and cold/warm query p50/p95, allocations, output bytes |
| Managed allocations/releases | total operations and bytes, plus current/retained objects |
| Peak RSS | compiler worker and retained LSP snapshot |
| Retired instructions | focused benchmark and representative production replay where available |
| Hash/string work | storage-key construction, string bytes compared, dictionary probes |
| Traversal work | typed/Core nodes visited and complete-program scans |
| Product size | row/edge counts and retained payload bytes |
| Generated C and native artifact size | benchmark worker, compiler, and affected generated program |
| Host C compile time | only when generated C shape or size changes |
| Production source size | net declarations/lines after the superseded path is deleted |

Before implementation, every issue classifies each of these seven metric
families as primary, guard-only, or not applicable:

1. median and tail latency for the affected compiler phase and production path;
2. managed allocation operations and bytes;
3. peak RSS and retained product/snapshot bytes;
4. retired instructions;
5. semantic work: traversals, hashes, string materializations, and probes;
6. product, generated-C, native-artifact, and net production-source size; and
7. affected tooling query latency, allocations, and output bytes.

The first six families are applicable by default to production compiler cuts.
The seventh is additionally applicable when a tooling snapshot or query
changes. Marking a family not applicable requires a written reason, a named
consumer/workload that does not exercise it, and reviewer agreement before the
candidate is measured. This prevents selecting only favorable metrics after
seeing results.

One family counts as improved only when its declared headline value improves
beyond measured host noise and no sibling guard value in that family crosses a
regression threshold. Neutral values do not count as improvements. “Most” means
strictly more than half of the applicable families: `floor(applicable / 2) + 1`.
Per-issue primary metrics must win or the issue is rejected. A combined
checkpoint must also win the majority calculation; it cannot hide a failed
primary issue behind unrelated later work.

### Default regression investigation thresholds

These thresholds trigger investigation; they are not substitutes for paired
raw data or an understanding of host noise:

| Metric | Investigate or reject when candidate is worse by |
| --- | ---: |
| Focused or production median latency | more than 2.0% |
| Focused, production, or query p95 latency | more than 5.0% |
| Managed allocation operations/bytes | more than 0.5% |
| Peak RSS or retained snapshot bytes | more than 1.0% |
| Retired instructions | more than 1.0% |
| Product/generated C/native artifact size | more than 1.0% |
| Net production source size | more than 2.0% |
| Host C compile time | more than 2.0% |

A candidate exceeding a threshold is reverted unless the regression is shown
to be measurement noise or a maintainer explicitly accepts a documented trade
for a larger combined checkpoint that has already been measured. Architectural
preference alone is not sufficient.

An enabling slice that is neutral may merge only when it deletes a real old
authority, has an immediate production consumer, and is paired with the next
measured slice in the same checkpoint. Do not accumulate a series of neutral
or slightly negative enabling layers on the promise of a later win.

### Measurement method

Use separate clean worktrees for baseline and candidate. Record commits,
compiler/worker SHA-256 values, host, architecture, compiler flags, and workload
arguments. Warm both variants, alternate execution order, retain raw samples,
and normally use three valid pairs. Add pairs only when the observed difference
is close to host noise or the counters are unstable.

Keep iteration cheaper than acceptance. During implementation, run the smallest
owned fixture and one baseline/candidate counter-screening pair. A failed screen
stops there; do not spend five pairs quantifying a known regression. Request
review before the final measurement so review fixes do not invalidate it. Once
the design and counters are stable, run one three-pair acceptance sample and the
broad changed-owner gate once. Additional pairs are for genuinely ambiguous
counter results, not the default feedback loop.

Headline timing runs remain uninstrumented. Allocation, logical counter,
sampling, and instruction measurements run as separate matrices because their
instrumentation perturbs latency.

The representative production replay loop is:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-semantic-roadmap.XXXXXX.json")
bin/blorp check --no-format --capture-typecheck-request "$capture" \
  blorp/src/main.brp

benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 180 --memory-limit 4G \
  --no-inventory --json

benchmarks/compiler_typecheck_replay "$capture" \
  --timeout 180 --memory-limit 4G \
  --no-inventory --json
```

Run allocation attribution separately with `--allocator-stats`. Store summaries
and raw TSV/JSON under `benchmarks/results/` with the baseline/candidate commits
and exact commands.

## Common Fast Feedback Ladder

Each step defines focused checks, then climbs this common ladder in proportion
to the ownership boundary changed:

```bash
# Smallest exact suite or fixture first.
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp

# Manifest-owned compiler feedback.
scripts/compiler-check --changed
scripts/compiler-check --stage typecheck

# Broad compiler semantics and ownership boundaries.
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test compiler-blorp-sanitize

# Tooling consumers when their projection changes.
scripts/test compiler-tools
scripts/test lsp

# Runtime and lifetime evidence when Core/CTFE/ownership changes.
scripts/test runtime
scripts/test leak
```

Before merge, run the exact broad gates owned by the changed boundary. Do not
substitute a benchmark checksum for compiler, sanitizer, leak, or LSP tests.

Structural tests should use small purpose-built tables and explicit malformed
inputs. Scaling fixtures should vary modules, declarations, overload width,
import density, type depth, body count, reference density, and failure density
independently so an improvement cannot hide a new quadratic dimension.

## Sequenced Checkpoints

| Step | Checkpoint | Depends on | Primary expected wins |
| ---: | --- | --- | --- |
| 0 | Baseline and authority inventory | Completed identity checkpoint | trustworthy evidence and explicit deletion targets |
| 1 | Publish one accepted semantic catalog | Step 0 | fewer retained carriers, copies, and reconstructed indexes |
| 2 | Normalize module visibility and binding precedence | Step 1 | lookup latency, hashes, allocations, completion readiness |
| 3 | Normalize body lifecycle and outcome storage | Step 1; Typecheck Phase 6 | body scheduling, allocations, retained state, deterministic assembly |
| 4 | Separate inferred, solved, and validated body facts | Step 3; Typecheck Phases 8-9 | fewer repeated walks, lower solver ownership, impossible invalid states |
| 5 | Publish occurrence and semantic edge tables | Steps 2 and 4 | LSP/lint latency, traversal work, exact impact analysis |
| 6 | Publish structured diagnostics and optional explanation provenance | Steps 2, 4, and 5 | string allocations, error usefulness, code actions |
| 7 | Replace the broad typed graph and attach CTFE results by ID | Steps 3-6; Typecheck Phase 10 | peak RSS, allocations, duplicate program size, Core admission safety |
| 8 | Expose compiler-owned semantic queries and migrate tools | Steps 5-7 | query latency, smaller context, deletion of tool-side reconstruction |
| 9 | Preserve IDs into Core declaration and relation tables | Step 7 | repeated Core indexes, name work, allocations, late-phase latency |

Steps are sequential where they share an authority. A later step may begin
design or failing-test work early, but production cutover must not overtake its
prerequisite product.

### Issue extraction rule

The steps above are checkpoints, not permission for one broad change. Before
implementation, split the active step into sequential issue packets. Each
packet moves one authoritative fact or relation through at least one production
consumer and deletes the corresponding old path. A packet should be describable
in one sentence.

Every packet records:

```text
Current authority and representation
Exact constructors, readers, writers, and observable ordering
Target row/edge/product and issuing owner
First production consumer
Old copies, scans, keys, or adapters deleted by the packet
Failing structural and end-to-end tests written first
Focused and broad validation commands
Primary expected resource win and guard metrics
Baseline/candidate workload and raw-result location
Acceptance, rejection, and rollback decision
```

A table foundation may be one packet only when its first consumer and deletion
fit in the same reviewed change. Otherwise keep the builder private to a
benchmark branch until the consumer cut is ready. Do not merge a public empty
abstraction for later packets to fill.

## Step 0: Baseline And Authority Inventory

### Context

The compiler has accumulated accepted tables, compatibility projections,
module views, typed-program traversals, and benchmark-only observations across
several successful migrations. The next cut must begin from current readers and
writers rather than the roadmap's historical description.

### Target contract

Create a checked-in inventory, either in the first implementation issue or a
small generated artifact, with one row per semantic fact family:

```text
Fact: accepted callable signature
Current authority: AcceptedCallableTable
Copied/projected into: ModuleView, OverloadEntry, TypedFunctionInfo
Reconstructed by: LSP semantic occurrence projection, Core name registry
Required consumers: body checking, CTFE, Core lowering, hover, completion
Last required lifetime: Core lowering / LSP snapshot depending on mode
Retirement target: importer-owned signature/name/path copies
```

Inventory at least:

- module and definition identity;
- accepted aliases, records, unions, constructors, fields, callables, globals,
  traits, implementations, and methods;
- source declaration locators and visibility;
- completed global headers and body outcomes;
- semantic type ownership and unresolved-meta state;
- module/import visibility;
- definition, reference, call, field, and type occurrences;
- diagnostics and rejection outcomes;
- CTFE work, dependencies, values, and rewritten initializers; and
- Core module/definition ownership and name projection.

Add logical counters before changing representation: rows built, indexes built,
string keys constructed, whole-program scans, typed nodes visited, table
publications, retained programs, and descriptive identity materializations.

### Implementation strategy

1. Trace constructors, mutators, readers, serializers, and test-only adapters.
2. Identify the one current semantic authority for each fact.
3. Mark every parallel copy as required projection, temporary compatibility, or
   deletion candidate.
4. Add counters at the narrow owner, not by parsing debug output.
5. Capture target-only and full compiler replay plus focused synthetic scaling
   matrices.
6. Record retained-object and peak-RSS checkpoints at accepted graph
   publication, CTFE completion, Core input projection, and LSP snapshot commit.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_typecheck_phase_profile accepted 100 8 32 64 4
benchmarks/compiler_typecheck_profile 2 2 64 128 retained
```

Use `benchmarks/compiler_typecheck_memory` for graph width, type-depth, lookup,
and retained-object modes relevant to the selected fact. Capture production
replay before any representation edit.

### Performance hypothesis

This step is measurement-only: it should not change production latency or
representation. Its value is to make later wins attributable and prevent a new
table from surviving without retiring an old copy, scan, string join, or
lifetime. Counter overhead belongs only in explicitly instrumented runs; the
ordinary compiler binary and headline latency runs must remain unchanged.

### Acceptance criteria

- Every fact family has one named current authority and complete consumer list.
- Every proposed new table has a named old reconstruction or copy to delete.
- Baseline replay responses and semantic checksums are retained.
- Baseline latency, allocation, RSS, instruction, product-size, and source-size
  rows are recorded or explicitly marked unavailable with a follow-up owner.
- Scaling fixtures independently vary the dimensions the next two steps change.
- No production representation changes are mixed into the baseline commit.

## Step 1: Publish One Accepted Semantic Catalog

### Context

Category-specific accepted tables already exist, but their coherent graph-owned
combination is not the primary product exposed to downstream consumers.
`TypecheckedGraph` exposes the module and definition authorities beside rich
module payloads, while accepted tables remain reachable through typechecking
products and per-module views.

### Target contract

Publish one opaque catalog containing the exact issuing tables and accepted
category tables. It is a capability, not a generic mutable database.

```blorp
private record AcceptedSemanticCatalogRep {
	module_table: ModuleTable,
	definition_table: DefinitionTable,
	aliases: AcceptedAliasTable,
	records: AcceptedRecordTable,
	unions: AcceptedUnionTable,
	callables: AcceptedCallableTable,
	globals: AcceptedGlobalTable,
	traits_and_implementations: AcceptedTraitImplementationTable
}

opaque type AcceptedSemanticCatalog = AcceptedSemanticCatalogRep
```

Catalog construction validates table provenance, module alignment, definition
category, row uniqueness, source order, and accepted header state. Consumers
receive narrow queries such as `semantic_catalog_callable`, not the private
record or its dictionaries.

Constructors and fields are separate logical entity families even when their
physical columns remain co-located with union/record storage for locality. The
current accepted union and record tables own their payloads. Their migration
must publish zero-copy opaque constructor/field table views over one canonical
allocation, or move those payload columns once and make union/record rows retain
ordered IDs/ranges. It must not copy the same constructor or field payload into
both a parent row and a new standalone table.

The implemented catalog follows the first representation: it stores each
accepted union and record table once, then projects opaque
`AcceptedConstructorTable` and `AcceptedFieldTable` logical capabilities over
those same allocations. Parent-keyed projections return variants and fields in
their canonical source order, validate the ID's issuing `DefinitionTable`, and
do not build flat copies or add retained payload owners.

### Implementation strategy

1. Add failing structural tests for incompatible module/definition tables,
   wrong-kind IDs, duplicate category rows, and observable ordering.
2. Construct the catalog at the existing accepted graph boundary using current
   table objects; do not copy their row lists.
3. Audit the nested accepted union-variant and record-field columns. Publish
   logical `AcceptedConstructorTable` and `AcceptedFieldTable` authorities as
   zero-copy views or migrate physical ownership once, with parent rows keeping
   ordered IDs/ranges rather than duplicate payloads.
4. Move one production consumer at a time to catalog queries.
5. Replace per-consumer compatibility checks with one publication proof where
   safe and measured.
6. Delete redundant graph-level carriers and reconstructed category indexes as
   each consumer moves.
7. Keep parser recovery and rejected modules in a separate recoverable product.

### Fast feedback

Run category-table suites and the accepted phase benchmark after each migrated
category:

```bash
# Iteration: smallest affected suite, then one baseline/candidate screen.
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp
benchmarks/compiler_typecheck_phase_profile accepted 5 8 32 64 4 memory

# Acceptance, once the screen and review are clean.
scripts/compiler-check --changed
```

Inspect generated C for unboxed IDs, one shared table retain per product rather
than per row, and absence of COW copies during catalog publication.

### Performance hypothesis

This step should reduce provenance checks, retained carrier objects, repeated
category index construction, and ARC traffic. Catalog construction should be
near zero-copy. A new wrapper that only increases retains and code size without
retiring a consumer path fails this step.

### Acceptance criteria

- One opaque accepted catalog proves all included tables share provenance.
- Every accepted constructor and field is addressable through one logical
  authority in canonical parent/source order. If payload columns move, parent
  union/record rows retain only ordered identity/range relations; if payloads
  remain co-located, the parent table remains their sole physical owner.
- Constructor/field publication does not duplicate payload storage or add a
  second independently owned authority.
- Rejected or pending declarations cannot construct it.
- At least one production consumer reads each included category through catalog
  queries before that category's slice merges.
- The corresponding superseded allocating graph carrier or index is deleted;
  a category build proof may retain the graph name only as a zero-cost opaque
  alias over the canonical table.
- Accepted output, diagnostics, IDs, and replay bytes remain exact.
- Allocations, retained bytes, and latency are neutral or better for each slice;
  the combined step improves a majority of its applicable resource metrics.

### Implemented result

Step 1 is complete. `AcceptedTypecheckGraph` now owns one
`AcceptedSemanticCatalog`, constructed once at graph completion from the exact
module, definition, alias, record, union, callable, global, and
trait/implementation tables. Construction derives exact expected category
counts from the accepted header graph and rejects missing rows, a mixed module
or definition provenance domain, or any global table with pending completion
slots. Type-header counts are accumulated as scalar metadata during the
existing successful header-build loop, avoiding a second graph traversal.
Only the opaque accepted graph representation contains the catalog. Recoverable
declaration and initializer outcomes retain separate semantic tables and cannot
publish the accepted capability.

Production body preparation and accepted-graph observations select all included
categories through the catalog. Frontend declaration profiling now reads
constructor and field rows from the catalog instead of reconstructing
constructor totals from type-header variants. The old `AcceptedAliasGraph`,
`AcceptedRecordGraph`, and `AcceptedUnionGraph` one-field record wrappers were
replaced by zero-cost opaque aliases over their canonical category tables.
Those aliases are phase-sealed build proofs: the catalog cannot accept a raw or
cross-category table, but the proof adds no allocation or retained owner. This
replaces three retained carrier allocations with one catalog allocation while
keeping module views as the narrow visibility projections required by body
checking.

Catalog tests cover coherent and mixed provenance domains plus completed-global
coverage. Existing category suites continue to own wrong-kind, duplicate-row,
ordering, and exact lookup behavior. The accepted graph integration suite
verifies that the production graph publishes the catalog and can read nonempty
constructor and field rows in parent/source order through the logical views.
The declaration-boundary check proves that alias, record, and union catalog
inputs require zero-cost sealed graph products rather than raw tables.

The closure screen compared the final implementation with immutable `main`
revision `66d510c9`. The focused profile used five accepted-stage iterations,
eight modules, 32 shapes per module, 64 probes per module, import fan-out four,
and allocator instrumentation. One alternating warm pair was sufficient to
confirm that the frozen representation retained the earlier directional wins;
it is counter evidence, not a wall-time study:

| Metric | Parent median/deterministic value | Step 1 median/deterministic value | Change |
| --- | ---: | ---: | ---: |
| accepted-stage retired instructions | 127,076,367,886 | 124,673,487,328 | -1.8909% |
| accepted-stage allocations | 1,684,396 | 1,684,391 | -5 per five iterations |
| accepted-stage releases | 1,565,183 | 1,565,180 | -3 per five iterations |
| accepted-stage retained objects | 119,213 | 119,211 | -2 |
| accepted-stage allocated bytes | 8,839,080 | 8,839,016 | -64 bytes |
| accepted-stage peak RSS | 83,050,496 bytes | 83,312,640 bytes | +0.3156% |
| profiled benchmark executable | 9,114,848 bytes | 9,166,432 bytes | +0.5659% |

The semantic and constructor-lookup checksums were identical.
The deterministic ARC reductions are consistent with replacing three carrier
allocations with the one accepted catalog. RSS and profiled-worker size remain
well below their 1% investigation thresholds.

For this representation-only cut, managed allocation/release work, retained
product memory, retired instructions, and native artifact size are primary.
Focused and whole-compiler latency, peak RSS, and semantic-work counters are
guards. Tooling-query cost is not applicable yet because Step 1 changes no LSP,
lint, or snapshot query; Step 8 owns that cutover. Generated program C and host
C compilation are also unchanged because the catalog is a compiler-internal
product and does not alter backend output.

The final production compiler executable shrank from 19,248,856 to 19,173,184
bytes (`-0.3931%`). Net production Blorp source grew by 864 lines, including
the catalog queries, proof boundary, consumer migration, and their explicit
validation paths. Host contention made wall time unsuitable for acceptance, so
no latency claim is made. Raw counters, hashes, commands, and the full
interpretation are in
[`benchmarks/results/compiler_accepted_semantic_catalog_step1_2026-09-10.md`](../../../benchmarks/results/compiler_accepted_semantic_catalog_step1_2026-09-10.md).

## Step 2: Normalize Module Visibility And Binding Precedence

### Context

Visibility is the missing relation behind exact completion, import
organization, resolution explanations, and many diagnostics. Current module
views retain several string-keyed maps for aliases, imported names, imported
constructors, modules, local names, and category authorities. These maps encode
real semantics, including source order and conflict behavior, but the relation
is spread across representation-specific containers.

Module visibility and request-position lexical visibility are distinct. This
step normalizes the module-level relation. Body-local variables, parameters,
type parameters, and lexical shadowing remain body-session facts until an
analysis request asks for a position snapshot.

### Target contract

```blorp
enum SemanticNamespace:
	ValueSemanticNamespace
	TypeSemanticNamespace
	ModuleSemanticNamespace

union VisibilityOrigin:
	LocalVisibilityOrigin
	SelectiveImportVisibilityOrigin(ModuleReferenceId)
	QualifiedImportVisibilityOrigin(ModuleReferenceId)
	PreludeVisibilityOrigin
	CompilerBuiltinVisibilityOrigin

opaque type DeclarationSourceOrder = Int
opaque type ImportedCandidateOrder = Int
opaque type PreludeDeclarationOrder = Int
opaque type BuiltinRegistryOrder = Int

union VisibilityOrder:
	LocalDeclarationVisibilityOrder(DeclarationSourceOrder)
	ImportedVisibilityOrder(ModuleReferenceId, ImportedCandidateOrder)
	PreludeVisibilityOrder(PreludeDeclarationOrder)
	CompilerBuiltinVisibilityOrder(BuiltinRegistryOrder)

union VisibleSemanticEntity:
	VisibleDefinitionEntity(DefinitionId)
	VisibleModuleEntity(ModuleId)
	VisibleCompilerBuiltinEntity(CompilerBuiltinIdentity)

record VisibleBindingRow {
	viewer_module: ModuleId,
	namespace: SemanticNamespace,
	local_name: String,
	entity: VisibleSemanticEntity,
	origin: VisibilityOrigin,
	order: VisibilityOrder
}
```

The canonical rows preserve every candidate and its exact origin/order. The
opaque order components are issued from the existing declaration, import,
prelude, and builtin orders; they are not interchangeable raw counters.
`VisibilityOrder` is not sorted through one guessed integer rank. The visibility
constructor applies the current resolver's explicit per-origin precedence,
first-import/newest-first rules, overload ordering, and tie/conflict behavior.
It publishes accepted winner/overload-set or rejected-conflict outcomes beside
the candidate rows. Derived indexes support `(module, namespace, local
spelling)` and qualified lookup, but index replacement never decides the
winner.

### Implementation strategy

1. Inventory current first-import/newest-first/conflict ordering for every
   namespace and declaration category.
2. Add structural fixtures for local/import/prelude collisions, privacy,
   aliases, selective imports, qualified modules, UFCS, overload order, and
   same-spelling value/type names.
3. Build canonical visibility rows during accepted module-view construction.
4. Validate indexes against rows and preserve candidate order exactly.
5. Represent winner, overload-set, shadowed, and rejected-conflict outcomes
   explicitly; add no generic numeric comparator that can reorder origin kinds.
6. Cut ordinary resolution queries over first; then cut LSP module-level
   visibility projection over.
7. Reduce `ModuleView` to a transient builder or a narrow query facade and
   delete maps that no longer own a unique semantic rule.
8. Define a separate optional `LexicalVisibilitySnapshot` only when completion
   work needs request-position locals. Do not persist complete lexical scopes in
   the compilation database.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_typecheck_name_lookup_profile
benchmarks/compiler_typecheck_profile 1 8 64 128 retained
scripts/test lsp
```

Add a scaling fixture varying modules, imports per module, overloads per name,
duplicate spellings, and query count. Record candidate visits, string hashes,
dictionary probes, and rows retained.

### Performance hypothesis

Canonical rows plus compact indexes should reduce repeated module-path strings,
per-module accepted payload copies, and reconstructed candidate lists. Query
latency and retired instructions should improve at increasing import/overload
width. Peak memory must include both row and index storage; adding every reverse
index eagerly is likely a regression.

### Acceptance criteria

- Every module-visible candidate has one row with exact origin and precedence.
- Lookup, privacy, collision, overload, import, and UFCS behavior is unchanged.
- No consumer reconstructs module visibility from parsed imports plus accepted
  category tables after cutover.
- Only indexes with a named production query remain.
- Lookup scaling, hashes/probes, allocations, and retired instructions improve
  in the intended workload.
- Whole typecheck latency and peak RSS remain within guard thresholds.

## Step 3: Normalize Body Lifecycle And Outcome Storage

### Context

Phase 6 established identity-keyed body checking with fresh body-local state and
accepted/recovered artifacts. The remaining database work is to make body
outcomes a retained table relation rather than rematerializing complete module
programs or treating a dictionary of artifacts as an incidental cache.

Typed expression trees remain row payloads in this step. Flattening expressions
would combine identity/outcome normalization with a much riskier locality
experiment.

### Target contract

```blorp
union BodyOutcome:
	AcceptedBodyOutcome(CheckedBodyArtifact)
	RejectedBodyOutcome(RecoveredBodyArtifact)

record BodyOutcomeRow {
	callable: CallableId,
	outcome: BodyOutcome,
	source_order: Int
}

opaque type BodyOutcomeTable = BodyOutcomeTableRep
```

If definition IDs are sparse below the graph frontier, use the explicit graph
base, a validated sparse slot representation, or a dense row ID relation. Do
not encode absence with an unexplained negative integer.

### Implementation strategy

1. Add tests for accepted, rejected, missing, wrong-kind, recursive, method,
   default-method, foreign, graphless, and deterministic shuffled scheduling.
2. Publish outcomes exactly once from the Phase 6 facade.
3. Separate source output order from scheduling/worklist order.
4. Make CTFE and ordinary program materialization consume the same row.
5. Replace whole-module body scans with module-to-body adjacency only where a
   real consumer requires module enumeration.
6. Delete body dictionaries, result-carrier copies, or rechecks replaced by the
   table.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained
benchmarks/compiler_typecheck_profile 2 2 64 128 retained
scripts/test compiler-blorp
```

Run source, reverse, and deterministic shuffled body order and compare exact
body fingerprints and diagnostics. Scale many small bodies separately from a
few large bodies.

### Performance hypothesis

The expected wins are fewer complete-program walks, fewer artifact dictionary
lookups, fewer program copies, and deterministic direct access by identity.
Memory should fall once duplicate body carriers and rematerialized module
programs are removed.

### Acceptance criteria

- Each source body has exactly one accepted or rejected row.
- CTFE and ordinary compilation reuse the same accepted artifact.
- Scheduling order cannot change output, diagnostic order, or IDs.
- Rejected bodies cannot be queried as accepted and cannot reach Core.
- Body checks, complete-program scans, allocations, and retained bytes decrease.
- No whole-compiler latency or peak-RSS regression exceeds the guard threshold.

## Step 4: Separate Inferred, Solved, And Validated Body Facts

### Context

Normalized storage is only trustworthy if table types prove semantic state.
Today the broad inference/finalization path relies on convention that metas have
been resolved and validation has already run. Typechecking Phases 8 and 9 own
the semantic change required here.

This step does not assume that globally interning every solved semantic type is
profitable. It first establishes state-safe products; type interning is a
separate measured sub-gate.

### Target contract

```blorp
opaque type InferredBody = InferredBodyRep
opaque type SolvedBody = SolvedBodyRep
opaque type ValidatedBody = ValidatedBodyRep

union BodyValidationOutcome:
	BodyValidationAccepted(ValidatedBody)
	BodyValidationRejected(RejectedSolvedBody)
```

`MetaId` belongs to one body-local solver session. No unresolved meta can be
constructed inside `SolvedBody`. `ValidatedBody` carries or references the
accepted facts needed by CTFE, semantic occurrence publication, and Core.

### Implementation strategy

1. Follow the Phase 8 solver/finalization issue to introduce nominal meta IDs,
   body-local solver ownership, and a meta-free solved-body constructor.
2. Follow the Phase 9 issue to classify validation rules by earliest sound
   phase and construct validated bodies only after all required checks pass.
3. Fuse compatible final whole-tree validations where this preserves diagnostic
   order and improves traversal work.
4. Publish solved/validated outcomes into the Step 3 body table without
   exposing partial bodies publicly.
5. Instrument solved type shapes, equality calls, repeated canonical values,
   hash cost, and retained bytes.
6. Prototype a `SemanticTypeTable` only in a focused benchmark. Accept it only
   if canonicalization is proven and the combined equality/copy/memory metrics
   improve. If rejected, retain canonical semantic type trees as row payloads
   and record the evidence.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
benchmarks/compiler_typecheck_profile 2 2 64 128 retained
benchmarks/compiler_typecheck_memory
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
```

Add fixtures with deep generic types, dimension constraints, recursive nominal
types, unresolved-meta failures, purity, tail recursion, resources, captures,
matches, and deterministic diagnostic ordering.

### Performance hypothesis

Body-local solver tables should shorten state lifetimes and reduce broad record
copying. Fusing redundant finalization/validation walks should reduce retired
instructions and latency. Type interning may reduce copies and equality cost,
but it may regress hashing, locality, and memory; it has an explicit rejection
path.

### Acceptance criteria

- No API accepting `SolvedBody` can receive unresolved metas.
- No CTFE/Core-facing API can receive a merely solved but unvalidated body.
- Validation ownership is explicit and no safety check is silently moved later.
- Diagnostic text/order remains exact until the diagnostic step intentionally
  changes rendering.
- Typed-node visits and solver-state retained bytes decrease.
- The type-table candidate is either accepted with multi-metric evidence or
  removed completely with results retained.

## Step 5: Publish Occurrence And Semantic Edge Tables

### Context

Definitions, references, calls, field selections, and type uses are currently
available in typed nodes, but tooling reconstructs many of them by traversing
complete typed programs. This duplicates work and leaves coverage incomplete
for locals, parameters, methods, type parameters, and foreign declarations.

### Target contract

```blorp
enum SemanticOccurrenceKind:
	DefinitionSemanticOccurrence
	ReferenceSemanticOccurrence
	CallSemanticOccurrence
	TypeUseSemanticOccurrence
	FieldSelectionSemanticOccurrence

union SemanticOccurrenceOwner:
	ModuleSemanticOccurrenceOwner(ModuleId)
	DefinitionSemanticOccurrenceOwner(DefinitionId)

opaque type BodyLocalSymbolId = Int

record BodyLocalSymbolRow {
	id: BodyLocalSymbolId,
	name: String,
	declaration_span: SourceSpan,
	kind: BodyLocalSymbolKind
}

struct ScopedBodyLocalSymbolId {
	owner: CallableId,
	local: BodyLocalSymbolId
}

private record BodyLocalSymbolTableRep {
	owner: CallableId,
	rows: List[BodyLocalSymbolRow]
}

opaque type BodyLocalSymbolTable = BodyLocalSymbolTableRep

union SemanticTypeParameterId:
	TypeDeclarationSemanticParameter(TypeParameterId)
	TraitSemanticParameter(TraitTypeParameterId)
	CallableSemanticParameter(CallableTypeParameterId)
	ImplementationSemanticParameter(ImplementationTypeParameterId)

union SemanticEntityId:
	GraphDefinitionSemanticEntity(DefinitionId)
	BodyLocalSemanticEntity(ScopedBodyLocalSymbolId)
	TypeParameterSemanticEntity(SemanticTypeParameterId)
	CompilerBuiltinSemanticEntity(CompilerBuiltinIdentity)

record SemanticOccurrenceRow {
	owner: SemanticOccurrenceOwner,
	target: SemanticEntityId,
	span: SourceSpan,
	kind: SemanticOccurrenceKind
}

record CallableEdgeRow {
	caller: CallableId,
	callee: CallableId,
	call_span: SourceSpan
}
```

Use separate canonical edge families when their invariants differ. A single
untyped `from/to/kind` table is not preferable to precise IDs and constructors.
Each `BodyLocalSymbolId` is meaningful only with the body-local table issued for
one `CallableId`; `ScopedBodyLocalSymbolId` carries that owner while the retained
occurrence product owns the corresponding table and proves the owner/table
relation. The table constructor assigns the dense row position as the local ID,
rejects duplicate or out-of-range IDs, and publishes the rows immutably. The
checked `SemanticTypeParameterId` umbrella preserves the
compiler's distinct type-declaration, trait, callable, and implementation
parameter domains rather than flattening their local indices into a colliding
integer.

### Implementation strategy

1. Define exact coverage requirements for compile, lint, and LSP products.
2. Publish edges when resolution/typechecking establishes them, or during one
   accepted-body traversal shared by all consumers.
3. Preserve source order independently from reverse-reference indexes.
4. Represent partial module/workspace coverage explicitly.
5. Add local/parameter/method/type-parameter identities before claiming those
   categories are complete.
6. Give body locals one body-owned issuing table and validate every local
   occurrence against its owning callable/table. Preserve the existing checked
   type-parameter identity variants through one explicit umbrella union.
7. Migrate LSP semantic-index construction, lint, CTFE dependency discovery,
   and impact analysis one consumer at a time.
8. Delete `semantic_program` reconstruction traversals after all required
   categories move.
9. Build source-occurrence tables only for requested analysis modes when
   compile-only retention would increase RSS without a consumer. Always-required
   call/dependency edges may remain in the accepted compilation product.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
scripts/test lsp
scripts/test compiler-tools
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained
```

Add dense-reference and sparse-reference fixtures, same-name symbols from
different modules, local shadowing, methods, generic type parameters, failed
dependencies, and UTF-16 LSP positions. Measure publication separately from
query latency.

### Performance hypothesis

LSP/lint queries should replace repeated O(program size) traversals with direct
table/index access. Compile-only mode must avoid paying to retain optional
source occurrences. Shared call/dependency edges should reduce CTFE and later
Core index construction.

### Acceptance criteria

- Every advertised occurrence category has exact identity and documented
  completeness semantics.
- Local IDs validate against one body-owned issuing table, and every
  type-parameter occurrence retains its original checked identity domain.
- LSP and lint do not rematch names or traverse `TypedProgram` to reconstruct
  migrated occurrences.
- Reference/call/type-use ordering is deterministic.
- Partial coverage cannot be returned as an ordinary complete empty result.
- Query latency, nodes visited, and allocations improve materially.
- Publication latency and snapshot RSS remain within guard thresholds; optional
  tables are not retained in modes without a consumer.

## Step 6: Publish Structured Diagnostics And Explanation Provenance

### Context

The parser retains structured expectations and help, while typechecking often
reduces failures to a message and optional span. Rendering early loses exact
definition ownership, related declarations, causal relationships, and safe
edits. The normalized semantic product can retain those relations without
forcing diagnostic consumers to rediscover them.

### Target contract

```blorp
union DiagnosticOwner:
	CompilationDiagnosticOwner
	ModuleDiagnosticOwner(ModuleId)
	DefinitionDiagnosticOwner(DefinitionId)

union DiagnosticPrimaryLocation:
	LocatedDiagnostic(SourceSpan)
	UnlocatedCompilationDiagnostic

union DiagnosticPayload:
	UnknownNameDiagnosticPayload(String, SemanticNamespace)
	TypeMismatchDiagnosticPayload(SemanticType, SemanticType)
	InvalidImportDiagnosticPayload(ModuleReferenceId, ModuleResolutionFailure)
	CompilerInvariantDiagnosticPayload(String)

union DiagnosticHelp:
	UseNameDiagnosticHelp(String)
	AddImportDiagnosticHelp(ModuleId, DefinitionId)
	ChangeTypeDiagnosticHelp(SemanticType)

record DiagnosticRow {
	code: DiagnosticCode,
	severity: DiagnosticSeverity,
	phase: DiagnosticPhase,
	owner: DiagnosticOwner,
	primary_location: DiagnosticPrimaryLocation,
	payload: DiagnosticPayload,
	help: Option[DiagnosticHelp],
	cause: Option[DiagnosticId]
}

record DiagnosticRelatedSpanRow {
	diagnostic: DiagnosticId,
	span: SourceSpan,
	role: DiagnosticRelatedRole
}
```

Compiler-proven edits and bounded resolution explanations are separate edge
tables. Each diagnostic family should use a precise payload variant rather than
a string template ID plus an untyped argument list. Only the internal-invariant
escape hatch retains free text. Human message/help/related labels are rendered
from typed payloads at CLI, JSON, LSP, and SARIF boundaries. Ordinary
compilation need not retain a complete candidate trace.

### Implementation strategy

1. Establish stable diagnostic IDs/codes and phase/category ownership.
2. Convert parser and typecheck producers to typed payload variants without
   changing human rendering.
3. Attach exact definition/module identities at the point of failure.
4. Aggregate body-local diagnostics in stable source order.
5. Add causal edges so one root failure can suppress or group consequences.
6. Add related spans and machine edits only when the compiler proves them.
7. Materialize human, JSON, LSP, and later SARIF forms at output boundaries.
8. Store optional call/trait/import candidate explanations only for analysis
   requests or actionable failures.

### Fast feedback

Convert one diagnostic family at a time. Tests assert code, primary/related
spans, help, and edits separately from renderer snapshots.

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-tools
scripts/test lsp
```

Add a typo/mistake corpus and cascade fixtures. Record diagnostic rows emitted,
rendered strings, string bytes allocated, and root/consequence ratios.

### Performance hypothesis

Late rendering should reduce repeated string concatenation and parsing of
locations from text. Causal grouping should reduce output volume and agent
context. Extra related-span/provenance storage is guarded by product policy and
must not inflate successful compile-only snapshots.

### Acceptance criteria

- Every migrated diagnostic has a stable code, phase, severity, and defensible
  primary span, or an explicit unlocated compilation owner when no source
  location exists. Rendering never invents a range.
- Migrated diagnostic message/help text is not eagerly stored; every external
  renderer consumes the same typed payload and related-span roles.
- Related spans and fixes reference exact compiler facts.
- Human output remains exact during structural migration; later wording changes
  have explicit fixtures.
- JSON and LSP render from the same rows.
- Successful compile-only allocation/RSS is neutral or better.
- Error-heavy latency, allocated string bytes, cascade count, and output size
  improve without hiding independent root errors.

## Step 7: Replace The Broad Typed Graph And Attach CTFE Results By ID

### Context

The broad typed graph mixes recoverable source state, accepted semantic state,
two complete typed-program forms, imports, diagnostics, CTFE completion, and
codegen concerns. It is the largest remaining barrier to precise lifetimes and
type-enforced phase boundaries.

This step is the Typechecking Phase 10 convergence point. It begins only after
the preceding accepted body and validation products are authoritative.

### Target contract

```blorp
private record RecoverableSemanticCompilationRep {
	identity: CompilationIdentity,
	recovery_modules: RecoveryModuleTable,
	diagnostics: DiagnosticTable,
	available_semantics: PartialSemanticCatalog
}

private record AcceptedSemanticCompilationRep {
	identity: CompilationIdentity,
	catalog: AcceptedSemanticCatalog,
	bodies: ValidatedBodyTable,
	edges: AcceptedSemanticEdges
}

private record CodegenReadyCompilationRep {
	identity: CodegenIdentityProjection,
	declarations: CodegenDeclarationProjection,
	bodies: CodegenBodyProjection,
	ctfe_results: CtfeGlobalResultTable,
	generated_definitions: GeneratedDefinitionTable
}
```

CTFE results are keyed overrides or materialization outcomes, not a second
complete typed program. The codegen-ready constructor proves all required
headers, bodies, validation, CTFE, imports, and generated-ID domains are valid.
It consumes or borrows `AcceptedSemanticCompilation` only while constructing
the narrow codegen projections; it does not retain the full accepted catalog,
analysis edges, diagnostic product, or source-oriented body product. Compile-only
execution can therefore release the accepted/recovery parent before Core.

### Implementation strategy

1. Add compile-time-negative tests proving recovery products cannot call Core.
2. Assemble recoverable and accepted products from existing phase products.
3. Replace `semantic_program`/`typed_program` duplication with one source-faithful
   body table plus CTFE result/override rows.
4. Migrate `check`, lint, and LSP to recoverable/analysis projections.
5. Migrate compile/run/test to `CodegenReadyCompilation`.
6. Construct narrow codegen identity, declaration, and body projections; verify
   that they do not retain the full accepted parent allocation.
7. Change Core preparation to accept only the codegen-ready projection.
8. Release syntax, recovery, occurrence, and analysis-only tables at their last
   consumer in compile-only mode.
9. Delete `TypecheckedModule`, `TypecheckedGraph`, CTFE Booleans, error-list
   validity checks, and raw-`TypedProgram` Core admission once consumers move.

### Fast feedback

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test lsp
scripts/test compiler-tools
scripts/test runtime
scripts/test leak
```

Use memory checkpoints before and after graph publication, CTFE, analysis
projection, Core input creation, and rich-graph release. Run accepted,
recoverable, error-heavy, CTFE-heavy, and no-CTFE fixtures.

### Performance hypothesis

This should produce the checkpoint's largest peak-RSS and allocation wins by
removing duplicate complete typed programs and shortening parsed/recovery data
lifetimes. Direct accepted tables should reduce rematerialization and whole
program validation scans. Product wrappers must not retain the full parent
graph accidentally.

### Acceptance criteria

- Core accepts only `CodegenReadyCompilation` or a narrower opaque projection
  constructible solely from it.
- Recoverable and accepted modules cannot be confused by flags or empty lists.
- CTFE results are attached by exact IDs without a duplicate complete program.
- The codegen-ready product owns only the identity/declaration/body columns Core
  requires and does not keep the full accepted semantic or analysis product
  alive.
- The broad `TypecheckedGraph` and raw typed-program Core entry are deleted.
- Check, lint, LSP, compile, run, and test use products matching their needs.
- Peak RSS, retained objects/bytes, allocations, and production product size
  improve materially; latency and generated artifact size do not regress.

## Step 8: Expose Compiler-Owned Semantic Queries And Migrate Tools

### Context

Tables are an internal ownership model. Humans, agents, and editor features
need stable semantic operations, not knowledge of private row layouts. The LSP
already has a semantic query session pattern that can be generalized without
exposing actor or typechecker state.

### Target contract

Representative operations:

```blorp
pure func semantic_entity_at(
	session: SemanticQuerySession,
	position: SourcePosition,
) -> SemanticQueryOutcome[SemanticEntityView]

pure func semantic_visible_entities(
	session: SemanticQuerySession,
	position: SourcePosition,
	namespace: SemanticNamespace,
) -> SemanticQueryOutcome[List[VisibleSemanticEntityView]]

pure func semantic_references(
	session: SemanticQuerySession,
	entity: SemanticEntityId,
	extent: SemanticQueryExtent,
) -> SemanticQueryOutcome[List[ReferenceView]]
```

Outcomes distinguish unavailable, stale, unsupported, partial, and complete
answers. External JSON materializes durable names, paths, spans, and artifact
identity; invocation-local integer IDs never masquerade as cross-run IDs.

### Implementation strategy

1. Define narrow query result views and exact completeness requirements.
2. Implement queries over canonical rows/edges and approved indexes only.
3. Add `blorp inspect module`, `symbol`, `at`, `references`, and `callers` as
   early command consumers with deterministic human and JSON output.
4. Migrate hover, definition, references, document symbols, highlights, lint,
   and future completion to the shared queries.
5. Add optional bounded explanation queries for import, callable, trait, and
   field resolution.
6. Delete tool-side AST walks, spelling joins, and independently reconstructed
   indexes as each capability moves.
7. Record query counters and expose a schema version/build identity in machine
   output.

### Fast feedback

```bash
scripts/test lsp
scripts/test compiler-tools
scripts/compiler-check --stage typecheck
```

Add JSON golden fixtures, incomplete-workspace cases, same-name identities,
request-position shadowing, repeated warm queries, and large-workspace scaling.
Measure snapshot construction separately from individual query latency.

### Performance hypothesis

Direct queries should sharply reduce query latency, allocations, and typed-node
visits. Shared immutable snapshots should make repeated queries cheap. Machine
output should reduce agent context by returning bounded rows rather than entire
typed AST/Core dumps.

### Acceptance criteria

- Every migrated capability queries compiler-owned facts through one session.
- No migrated tool reconstructs visibility, definition, or reference identity
  from source spelling.
- Complete, partial, stale, and unavailable outcomes remain distinct.
- Human and JSON results are deterministic and schema-versioned.
- Warm query latency, allocations, and output bytes improve materially.
- Snapshot publication and compile-only paths remain within all guard thresholds.

## Step 9: Preserve IDs Into Core Declaration And Relation Tables

### Context

After the frontend product is normalized and codegen admission is explicit,
Core can preserve source semantic ownership rather than encoding it in prefixed
names and rebuilding callable/type/reachability indexes across passes. This is
the first lower-confidence horizon and requires a fresh pass-by-pass audit.

This step normalizes declarations and stable relations first. Existing
`CoreExpr` trees remain payloads unless a separate arena experiment proves a
multi-metric win.

### Target contract

```blorp
record CoreDefinitionRow {
	id: CoreDefinitionId,
	source: CoreDefinitionProvenance,
	owner_module: ModuleId,
	kind: CoreDefinitionKind
}

record CoreFunctionRow {
	definition: CoreDefinitionId,
	body: CoreExpr,
	semantic_callable: Option[CallableId]
}

record CoreCallEdge {
	caller: CoreDefinitionId,
	callee: CoreDefinitionId
}
```

Specialization and synthesis append rows with explicit generated provenance.
DCE publishes liveness or a compact backend projection; it does not renumber
surviving semantic identities.

### Implementation strategy

1. Inventory each Core pass's declaration scans and private indexes.
2. Preserve module/definition IDs through lowering before changing expression
   representation.
3. Introduce function/global/nominal-type rows and canonical call/type-use edges.
4. Promote an index only when at least two adjacent production consumers rebuild
   it or one consumer has measured scaling cost.
5. Migrate one pass cluster at a time and delete its superseded scan/index.
6. Keep C-safe symbol materialization in Stage 10.
7. Evaluate a `CoreExprId` arena only as a reversible benchmark candidate with
   locality, COW, allocation, instruction, and code-size evidence.

### Fast feedback

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test runtime
scripts/test leak
```

Dump Core before/after each migrated pass and audit generated C. Use fixtures
with many declarations, deep expressions, specialization growth, unions,
closures, resources, reuse, and DCE-heavy graphs.

### Performance hypothesis

Shared declaration/edge tables should reduce repeated whole-program scans,
semantic name hashing, dictionary construction, allocations, and late-Core
latency. Expression arenas may improve sharing or may damage locality; no arena
survives a negative measurement.

### Acceptance criteria

- Core semantic ownership is ID-backed through the migrated pass cluster.
- Generated definitions have explicit source/generated provenance.
- No migrated pass rebuilds an index already owned by the Core product.
- Semantic names are not used as ownership or join keys after the naming
  boundary moves.
- Core dumps, runtime behavior, ownership, and generated C remain correct.
- The pass cluster improves a majority of applicable latency, allocation,
  instruction, memory, and code-size metrics without a guard regression.

## Cross-Step Testing Matrix

| Concern | Required coverage |
| --- | --- |
| Provenance | unrelated tables, same numeric IDs, graphless/compiler/generated rows |
| Ordering | module discovery, definition allocation, overloads, imports, diagnostics, bodies |
| Rejection | parser recovery, header failure, body failure, CTFE failure, partial workspace |
| Visibility | local, private, selective, qualified, prelude, aliases, UFCS, shadowing |
| Identity | callable, global, type, constructor, field, trait, implementation, method |
| Bodies | ordinary, recursive, generic, method, default, foreign, resource, concurrent |
| Relations | calls, function values, global references, type uses, fields, implementations |
| Tooling | check, lint, hover, definition, references, highlights, completion prerequisites |
| Lifetime | compile-only release, recoverable analysis, retained LSP snapshot, Core handoff |
| Scaling | modules, declarations, imports, overloads, type depth, bodies, references, failures |

Every table constructor needs negative invariant tests. Every query needs exact
complete/partial coverage tests. Every representation cut needs at least one
end-to-end production consumer test proving the old reconstruction is gone.

## Explicit Non-Goals

- A SQL parser, general relational algebra engine, or runtime-reflective
  compiler database.
- Cross-invocation integer identity or a persistent incremental cache.
- Retaining mutable lexical scopes, solver metas, CTFE stacks, or Core worklists
  as durable semantic tables.
- Flattening the full parsed AST, typed expression tree, or Core expression tree
  before a focused measurement proves the benefit.
- Building every possible reverse index in anticipation of future tools.
- Changing source-language semantics, syntax, or existing command behavior as
  part of a representation migration. Step 8 may add the explicitly scoped,
  schema-versioned `blorp inspect` query interface; that does not authorize
  unrelated changes to existing public APIs.
- Keeping both the new normalized product and the complete old graph after a
  vertical cut reaches production.

## Completion Criteria

The normalized semantic compilation checkpoint is complete when:

1. accepted category tables are published through one coherent opaque catalog;
2. module visibility and precedence are explicit relations with exact origins;
3. every body has one identity-keyed accepted or rejected outcome;
4. inferred, solved, and validated bodies are distinct products;
5. definitions, references, calls, type uses, and field selections required by
   advertised tools are authoritative rows/edges rather than reconstructed
   typed-tree facts;
6. diagnostics retain stable codes, ownership, spans, and causal relations and
   render at external boundaries;
7. recoverable, accepted, and codegen-ready compilations are distinct and Core
   accepts only the codegen-ready refinement;
8. CTFE results attach by exact identity without retaining a second complete
   typed program;
9. LSP, lint, inspection, and compiler consumers use shared semantic query APIs;
10. migrated reconstruction, string-join, duplicate-program, and parallel-index
    paths are deleted;
11. IDs never escape without their issuing product or masquerade as cross-run
    identity;
12. compile-only and analysis modes retain only their named products;
13. exact semantic, diagnostic, LSP, Core, runtime, sanitizer, and leak gates
    pass; and
14. the combined checkpoint improves more than half of its applicable primary
    resource metrics, including latency, allocations, retired instructions,
    peak/retained memory, traversal/hash work, and product/artifact size, with no
    untriaged material guard regression.

The success condition is not the presence of more tables. It is that compiler
facts have one explicit owner, consumers ask bounded questions of those facts,
old reconstruction disappears, invalid semantic states become unrepresentable,
and the compiler and its tools do less total work.
