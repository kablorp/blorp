# Issue 56: Establish One Compilation Module Table

**Status:** Implemented; awaiting integration

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

## Implementation Result

Stage 04 now owns the sole opaque `ModuleId = Int` domain and `ModuleTable`.
The table retains one ordered `ResolvedModuleIdentity` column and one
canonical-path index. Exact identity lookup probes that index and validates the
row's complete resolved identity, so a second identity-key dictionary is not
retained. The table also provides an allocation-identity compatibility check
for provenance-sensitive boundaries.

`FrontendGraph` retains that table plus table-aligned finalized-program and
module-surface columns. Roots, importers, and resolved module-reference outcomes
use `ModuleId`. Compatibility accessors can still materialize a
`FrontendModule`, but the graph no longer retains another complete list of
identity-bearing `FrontendModule` records.

The direct Stage 06 bridge passes the exact graph-owned table into
`indexed_graph_build_for_module_table`. That constructor validates payload
length and every row identity, resolves the target candidate through that
table, and only then publishes table-aligned prepared module payloads.
Dependency-ID selection and the direct frontend-ID entrance require the
issuing table and reject a different allocation before positional access. This
keeps each `ModuleId` one unboxed integer while enforcing provenance at product
boundaries. The descriptive replay constructor invokes the same Stage 04 table
constructor once, then enters the same indexed representation. The independent
`PreparedModuleId`, `FrontendModuleId`, their conversion helpers, and the Stage
06 `dependencies_by_path` index are deleted.

No `SourceId` exists at this stage, so the module row deliberately owns only
resolved identity. Source files remain in phase-specific finalized/prepared
payload columns. Adding a speculative source table was outside this issue.

### Preserved behavior

The focused tests retain exact module/root/reference/source ordering, repeated
and unresolved import occurrences, duplicate and conflicting-origin errors,
definition allocation, graph provenance, accepted authority ownership, and
direct-versus-replay typed output. Two independent tables can both issue the
same numeric row, but table-paired selection rejects the foreign ID. Three
conflicting claims for one canonical path also prove that every diagnostic
retains the original first claimant rather than the previous duplicate.

During implementation, sanitizer inspection exposed an ownership-codegen
constraint: retaining a field-projected `ResolvedModuleIdentity` in a branch
local did not reliably retain the value in generated C. Canonical table rows
are therefore reconstructed directly into the owning list append, and
compatibility import-edge projections continue to build from the owned
`FrontendModule.identity` field. This source shape is covered by sanitizer and
leak tests; the table API does not expose this compiler implementation detail.

### Deterministic work evidence

The existing indexed-phase function instrumentation reports the exact
production constructor boundary. For five iterations with 64 dependency
modules it observed five `indexed_graph_build` calls, five `ModuleTable`
publications, 325 canonical identity rows/index entries, and 325
`resolved_module_identity_storage_key` calls. Each normalized input therefore
publishes one table and 65 aligned prepared payload rows. The direct bridge has
zero Stage-04-to-Stage-06 integer translation calls: it passes `ModuleId`
values and the issuing table directly. Repeated/unresolved reference behavior
is covered by exact structural tests; the existing profile does not expose a
separate exact low-level list-read or dictionary-probe counter.

Generated C at
`logs/issue56-compilation-module-table/generated-c-final/` confirms that `ModuleId`
is an unboxed `long`, the table has one identity-row loop and one non-error
table construction, and no per-ID heap allocation is emitted. The final
generated-C inspection separately covers both `FrontendGraphRep` and
`IndexedGraphRep`; raw logs are ignored.

### Measurements

Baseline was `0b5258dab08790a40a2c2efbcd0451bdb79ead16` on macOS arm64.
All matrices used three alternating baseline/candidate pairs after warmup.

The uninstrumented import-graph replay matrix varied module count independently
(`1`, `16`, `64`) and import fan-out at 64 modules (`0`, `4`, `16`), with eight
functions per module and three in-process iterations. All 30 samples had exact
matching artifact/declaration/import/error/checksum fields and
`workload_valid=True`. At 16/64 modules, candidate median elapsed ranged from
`-0.07%` to `+1.87%`, retired instructions from `+0.04%` to `+0.16%`, and peak
RSS from `-0.25%` to `+0.71%`: neutral within local measurement noise.

The same fixture also has a direct mode that constructs an actual
`FrontendGraph` and executes the graph-owned table handoff. Baseline and
candidate used byte-identical fixture and runner sources (SHA-256
`2222314bfcf52bfca4fdc265743fcbbf4087ac542bb58e3509b3ba163d58ebe2`
and `45b96e4d0a16626f4866607cecbc98ba7a070b81e746167ea9601b0d33583805`)
with three alternating pairs at module/fan-out shapes `1/0`, `16/4`, `64/0`,
`64/4`, and `64/16`. Every sample had exact artifact, source/typed declaration,
resolved-import, import-binding, error, and checksum fields. Candidate
allocations and releases changed by only `+0.02%` to `+0.03%`; retained objects
and bytes were exactly `1` and `96` in both builds. Three-pair elapsed medians
ranged from `-6.8%` to `+5.0%`; four additional pairs at both 64-module
sentinels produced seven-pair medians of `+2.0%` at fan-out 4 and `-0.14%` at
fan-out 16. Direct-path latency is therefore treated as noisy and neutral, not
as a speedup claim. Raw and summary logs are under the ignored
`direct-import-matrix-identical/` directory.

The allocator-enabled indexed-phase matrix used 20 iterations at 1, 16, 64,
and 256 modules. Exact output counts and checksums matched. Allocations changed
by `+0.28%` to `+0.40%`, allocated bytes by `+0.72%` to `+2.03%`, retained
objects by `+0.94%` to `+2.76%` (the largest percentage is the two-row case),
and process RSS by `-0.23%` to `+0.06%` outside the smallest process-floor row.
The instrumented elapsed/instruction results favored the candidate by roughly
13-23%, but are not used as a production speed claim because changing the
instrumented function set can change profile-registry overhead.

Production compiler replay used request SHA-256
`de93c30a153c0e60a75c3fdb548866d08eb76ebab1721266d5b16f8ddb539b4c`
and three alternating allocator-enabled target-only pairs. Baseline worker
SHA-256 was `e653ae702e9b3969d6efac77db5652d16f867b27da8049dafa36f54ae69ed2c4`;
candidate worker SHA-256 was
`ed955f0062ae6f6ef6c4f2f8c76c177d0dc8827b8e6ccf97e06554a3d29b5dd6`.
Every run was verified, cleanly bounded, and returned the same 1,755,080-byte
response with SHA-256
`f11d97d6f1cf5ac91ae76d1461ded8ba5a8884f1217504621bf3707d75363851`.
Candidate medians were elapsed `-0.14%`, peak RSS `+0.02%`, allocations
`+0.0006%` (366 of 58.9 million), releases below `+0.0001%`, current objects
`+0.0068%`, and allocated bytes `+0.0035%`. The final worker includes the
provenance guards and closure-free ID lookup; this is production-neutral.

### Remaining descriptive boundaries

Issue 57 still owns migration of descriptive identity in
`ModuleLoadCandidate`, `LoadedModule`/`PreparedModule`, graph-backed declaration
and definition records, accepted authorities, typecheck state, typed graph
outputs, diagnostics, semantic/LSP projection, and compatibility accessors.
`TypecheckGraphRequest` remains the sanctioned serialized replay boundary.
Multi-root frontend validation plus current lint/purify compatibility helpers
also enter through that descriptive request because they preserve the legacy
dependency-before-other-roots definition-allocation order; Issue 57 must
migrate that ordering explicitly rather than silently adopting native table
order.
CTFE and Core remain explicitly outside this issue.

**Recommendation:** accept this foundation and proceed to Issue 57. It deletes
a real duplicate ID namespace and a redundant Stage 06 path index, has direct
production consumers, preserves semantics, and is neutral on production replay.
