# Issue 56: Establish One Compilation Module Table

**Status:** Proposed

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:** Issue 55 is complete and retains Stage 04 module/reference
IDs through the direct Stage 06 handoff. The current accepted Stage 06 dense-ID
work must be present before this issue starts. Re-audit the branch because the
roadmap was written while the final `TypeId` owner migration was still
uncommitted.

**Blocks:** Issue 57 and every later table that uses `ModuleId` as a foreign
key.

## Objective

Create one compilation-owned `ModuleId` domain and immutable module identity
table during Stage 04 graph construction, retain that exact table through the
Stage 06 `IndexedGraph`, and remove the independent Stage 06
`PreparedModuleId` domain.

At completion:

```text
ModuleId -> one ModuleTable row

Frontend module payloads[ModuleId]
Prepared module payloads[ModuleId]
Bound module payloads[ModuleId]
```

all use the same integer domain. Stage-specific payload tables may differ, but
the meaning of `ModuleId(7)` is established once and never reconstructed or
renumbered inside the compilation.

This issue does not migrate all declaration identities, CTFE, Core, LSP
storage, source spans, or semantic types.

## Why This Is The First Issue

The compiler currently has two dense module ID types:

- `FrontendModuleId` in
  `blorp/src/compiler/stage_04_modules/frontend_graph.brp`; and
- `PreparedModuleId` in
  `blorp/src/compiler/stage_06_typecheck/graph/indexed_graph.brp`.

Stage 04 has already assigned deterministic module and module-reference rows.
Stage 06 nevertheless creates a new `LoadedModuleSet`, module list, path index,
target position, and graph-local integer domain. Recent Stage 06 migrations
then carefully prove that a `PreparedModuleId` belongs to the correct
`IndexedGraph` before using it.

Those checks are necessary with two graph-local domains, but they are not the
desired endpoint. The compilation needs one identity spine whose table is
retained by each phase product that carries its IDs.

The important distinction is:

```text
stable module identity row       owned by ModuleTable
phase-specific module payload    aligned to ModuleId
```

Do not solve this by putting the complete frontend or prepared module record in
the identity table. Parsed programs, surfaces, loaded programs, bound views,
and prepared environments have different lifetimes and phase invariants.

## Required Reading

Before editing, read:

- `AGENTS.md`;
- the normalized compilation database roadmap;
- `GRAPH_MODULE_ID_ROADMAP.md` and its rejection evidence;
- `STAGE6_DENSE_MODULE_INDEX_MIGRATION_ROADMAP.md`;
- Issues 45-50 and 55;
- `blorp/src/compiler/pipeline.brp`;
- all files under `blorp/src/compiler/stage_04_modules/` that read or construct
  `FrontendGraph`, `FrontendModuleId`, `ResolvedModuleIdentity`, or
  `ModuleIdentity`;
- `stage_06_typecheck/frontend_graph_typecheck.brp`;
- `stage_06_typecheck/bridge.brp`;
- `stage_06_typecheck/graph/indexed_graph.brp`;
- `stage_06_typecheck/modules/bound_module_graph.brp`; and
- the direct/replay, frontend graph, indexed graph, module binding, LSP, leak,
  and benchmark tests that construct these products.

Inventory every constructor and accessor for both ID domains before editing.
Record which callers can construct a graph without Stage 04, including replay,
direct-program tests, compiler surfaces, and anonymous modules.

## Current Representation

Stage 04 currently retains:

```blorp
private record FrontendGraphRep {
	modules: List[FrontendModule],
	module_ids: List[FrontendModuleId],
	module_ids_by_identity: Dict[String, Int],
	roots: List[FrontendModuleId],
	is_root_by_module: List[Bool],
	references: List[FrontendModuleReference],
	resolution_by_reference: List[FrontendModuleReferenceResolution],
	reference_ids_by_module: List[List[FrontendModuleReferenceId]]
}
```

`FrontendModule` combines the resolved identity with a finalized parsed
program and `ModuleSurface`.

The direct Stage 06 adapter then creates `ModuleLoadCandidate` values and an
`IndexedGraph` whose private representation contains:

```blorp
private record IndexedGraphRep {
	target: PreparedModule,
	module_table: List[PreparedModule],
	target_index: Int,
	dependencies_by_path: Dict[String, Int],
	definition_index: DefinitionIndex
}
```

`PreparedModuleId` is the integer position in this second module payload list.
`PreparedModuleScope` pairs the graph with that ID to carry provenance.

The replay boundary does not possess a Stage 04 `FrontendGraph`; it decodes
descriptive module records and must normalize them once before entering the
same Stage 06 implementation.

## Required Design

### Low-level ownership

Add a low-dependency Stage 04 module that owns the opaque identity table and ID
types. The exact filename and private representation should follow the final
dependency audit, but the public semantic boundary should be equivalent to:

```text
opaque ModuleId = Int
opaque ModuleReferenceId = Int
opaque ModuleTable

ModuleTable row:
  ResolvedModuleIdentity
  selected SourceId/source locator when available
```

The table must provide narrow accessors for:

- exact row count and deterministic ID order;
- resolved identity, canonical path, and origin for a valid `ModuleId`;
- exact resolved identity to `ModuleId` lookup;
- exact table/domain compatibility where a provenance check remains needed;
  and
- construction/validation errors with current diagnostic semantics.

Do not expose its representation or an unchecked public constructor accepting
arbitrary `(Int, row)` pairs.

### Frontend graph

`FrontendGraph` owns the `ModuleTable`. Its phase payload remains aligned to
the table:

```text
ModuleId -> finalized program and ModuleSurface
```

Existing public accessors may temporarily project a `FrontendModule` value for
callers that still need it, but the graph must not retain a second complete
identity list as another source of truth. A projected compatibility value is
acceptable only if it is built on demand and scheduled for removal by a named
consumer migration.

Module-reference rows continue to use `ModuleReferenceId`, importer
`ModuleId`, and exact resolved/unresolved outcomes. Repeated source import
occurrences remain separate rows. Source order remains represented by the
per-module ordered reference-ID list.

### Indexed graph

`IndexedGraph` retains the exact same `ModuleTable` and a separate aligned list
of Stage 06 `PreparedModule` payloads. Replace `PreparedModuleId` with
`ModuleId`; do not add an alias that lets both domains survive indefinitely.

The constructor must prove:

- prepared payload count equals module-table count;
- each prepared payload's materialized identity equals its `ModuleId` row;
- target and selected dependency IDs belong to the table;
- deterministic row order is unchanged; and
- definition-index allocation order is unchanged.

`PreparedModuleScope` may continue to retain an `IndexedGraph` plus
`ModuleId`. Same-allocation/same-table checks remain useful for proving that a
scope and phase payload belong together, but module semantic identity comes
from the shared table.

### Replay and graphless construction

The replay decoder invokes the Stage 04-owned constructor to build one
legitimate `ModuleTable` from its complete descriptive request before Stage 06
work starts. Direct and replay paths therefore share one constructor and one ID
domain; replay is a sanctioned reconstruction boundary, not a second issuer.

Do not serialize invocation-local IDs. Do not use a magic module ID for an
anonymous module, compiler surface, or invalid request. This issue must record
which graphless paths need a one-module table, compiler-owned rows, or a
separate explicit identity variant. Implement only the construction needed by
current production and focused tests; stop if supporting a path requires an
unchecked table API.

## Implementation Sequence

### 1. Establish failing structural tests

Before production edits, add tests proving:

- Stage 04 and Stage 06 currently expose distinct ID domains or perform a
  translation/reconstruction boundary;
- deterministic module order for target, dependencies, roots, and repeated
  references;
- two independently constructed tables can both issue numeric row zero but
  are not provenance-compatible;
- equivalent descriptive graphs constructed through direct and replay paths
  produce equivalent rows and results;
- duplicate identity/origin/path failures preserve exact diagnostics; and
- empty, singleton, chain, diamond, dense, repeated-import, source-package,
  standard-library, native, and unresolved-reference cases have exact counts.

Tests must use public/opaque behavior. Do not expose table lists or private
graph representations solely for assertions.

### 2. Extract the Stage 04 module table

Move ID creation, row access, exact identity indexing, and table validation
behind the new opaque owner. Build required indexes in the existing graph
construction traversal. Keep construction-only dictionaries private and
discard them after publication.

Do not change discovery order, resolver calls, parser/surface construction, or
diagnostic order.

### 3. Align frontend payloads and references

Make `FrontendGraph` retain the table and table-aligned frontend payloads.
Adapt roots, module accessors, references, and resolution outcomes to the new
`ModuleId` type. Remove duplicate retained ID lists if dense ID iteration can
be issued by the table without allocations; verify generated C before choosing
an accessor shape.

### 4. Normalize the direct and replay Stage 06 entrances

The direct path passes the existing table. The replay path constructs the same
shape once. Both produce aligned prepared module payloads and call one
`IndexedGraph` constructor.

Do not retain the descriptive replay request after normalized construction.

### 5. Remove the Stage 06 ID domain

Change `PreparedModuleScope` and existing dense graph-owned consumers to
`ModuleId`. Delete `PreparedModuleId`, its conversion helpers, and any map
whose only purpose was translating Stage 04 positions into Stage 06 positions.

This is a mechanical type migration. Do not migrate declaration-category
ownership or redesign `DefinitionIndex` in this issue.

### 6. Delete compatibility scaffolding

Remove temporary dual-ID adapters and diagnostic accessors. Retain only the
opaque table API, exact production consumers, and compact benchmark
observation support with existing precedent.

## Required Tests

At minimum:

- frontend graph and frontend graph service suites;
- direct/replay frontend graph typecheck equivalence;
- indexed graph construction, lookup, selection, and provenance;
- bound module graph and module visibility/binding suites;
- exact root/dependency/source order and definition-ID frontier;
- repeated module-reference occurrences and unresolved outcomes;
- duplicate identity and conflicting-origin diagnostics;
- compiler prelude/standard-library/source-package/native-package modules;
- independently constructed graph row-number collision;
- leak checks for nested table/payload projections; and
- LSP analysis graph tests that consume Stage 04 graph accessors.

Every direct/replay pair must compare typed output, diagnostics and help text,
module surfaces, import bindings, selected modules, and the definition-ID
frontier.

## Measurement

Extend existing compiler module/typecheck profiles rather than creating a
parallel framework. Record separately:

- module rows and reference rows;
- identity-index entries;
- Stage 04-to-06 ID translations;
- prepared payload rows;
- module identity storage-key constructions;
- canonical-path dictionary probes;
- table/list reads;
- table publications;
- allocations, releases, retained objects/bytes, elapsed, instructions, and
  peak RSS; and
- semantic checksum and exact diagnostics.

Run a matrix varying module count, import fan-out/density, repeated imports,
unresolved imports, root count where supported, and direct versus replay
construction.

Inspect generated C and prove:

- `ModuleId` is an unboxed integer;
- no table or graph reference is retained per ID;
- one identity table is built per normalized input;
- frontend and prepared payloads are table-aligned; and
- no per-row compatibility record allocation was introduced.

Run at least three alternating production self-check/replay pairs if the
worker can exercise the normalized boundary. Require byte-identical responses
and allocator/RSS data.

## Acceptance Criteria

1. One opaque `ModuleId` domain is issued by the Stage 04 module table.
2. `FrontendGraph` and `IndexedGraph` retain the same table and ID meaning.
3. `PreparedModuleId` and all translation helpers are deleted.
4. Stage-specific module payloads are aligned and validated without retaining
   a second identity source of truth.
5. Direct and replay inputs normalize once and converge before semantic work.
6. All ordering, identity, diagnostic, visibility, and definition-allocation
   behavior is exact.
7. Generated C contains unboxed IDs and no per-ID table/graph ownership.
8. Leak and sanitizer checks pass.
9. No material allocator, elapsed, instruction, or RSS regression is accepted.
10. The issue documents exact retained tables and every remaining descriptive
    module boundary for Issue 57.

An elapsed improvement is desirable but not required independently. This issue
may be accepted as foundation only if it deletes a real duplicate ID/
reconstruction boundary, has immediate production consumers, and is neutral or
better on deterministic resource measurements.

## Stop Conditions

Stop and consult before:

- changing module discovery or import precedence;
- changing row order to simplify table construction;
- adding table references to every module/declaration ID;
- retaining both old and new ID domains after cutover;
- creating process-global or cross-run module IDs;
- serializing invocation-local IDs;
- using path hashes or negative integers as IDs;
- changing `ResolvedModuleIdentity` semantics; or
- broadening into declaration, CTFE, Core, or LSP representation work.
