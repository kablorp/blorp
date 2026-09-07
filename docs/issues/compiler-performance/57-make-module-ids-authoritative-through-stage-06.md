# Issue 57: Make Module IDs Authoritative Through Stage 06

**Status:** Proposed; starts only after Issue 56 is accepted

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependency:** Issue 56 provides the one compilation-owned `ModuleTable` and
`ModuleId` domain used by both Stage 04 and Stage 06.

**Blocks:** Issue 58 and normalized definition/category tables.

## Objective

Make `ModuleId` the default owner representation for graph-backed Stage 06
facts. Move graph-backed declaration, definition-index, typecheck-state, bound
module, accepted-authority, and semantic preparation paths away from embedded
`ModuleIdentity` and canonical module-path strings. Retain the shared module
table once per owning graph/product and materialize descriptive identity only
at an explicit diagnostic, replay, compiler-surface, or semantic/LSP projection
boundary.

This issue must not add a managed module-table/graph/scope field to each
declaration ID. The module table belongs to the containing accepted product;
entity rows carry unboxed `ModuleId` foreign keys.

At completion, the normal Stage 06 direction is:

```text
ModuleId
  -> ModuleTable row when descriptive facts are required
  -> dense module-aligned Stage 06 payloads
  -> declaration/category rows with ModuleId owner
  -> semantic projection at the Stage 06 output boundary
```

## Scope Boundary

This issue includes graph-backed Stage 06 production paths and the explicit
normalization required for current direct/replay/compiler-surface entry points.
It does not:

- redesign import resolution or Stage 04 table order;
- intern semantic types;
- flatten typed expression trees;
- redesign lexical `Env`/`Scope`;
- change definition-ID allocation order;
- carry IDs through CTFE or Core lowering;
- change LSP protocol identity or snapshot revision semantics; or
- begin the later normalized callable/type/global table program beyond the
  owner relation needed to remove `ModuleIdentity`.

## Required Audit

Before editing, enumerate every `ModuleIdentity`,
`ResolvedModuleIdentity`, `module_path`, `module_name`,
`module_identity_*`, and module storage-key read/write under
`blorp/src/compiler/stage_06_typecheck/`. Classify each use as:

| Class | Required action |
| --- | --- |
| Graph-backed entity owner | Replace with `ModuleId` |
| Module-table lookup/index | Replace with table/list access or retain only as an external-key index |
| Diagnostic rendering | Materialize from `ModuleTable` at rendering boundary |
| Replay decode/encode | Normalize on decode; materialize on encode |
| Compiler builtin/surface | Assign a legitimate compiler-owned table row or retain an explicit non-graph variant |
| Anonymous/direct program | Construct a legitimate one-module domain or retain an explicit graphless variant |
| Exported semantic/LSP projection | Materialize current durable value at projection until the snapshot owns `ModuleTable` |
| Genuine source spelling | Retain; source spelling is not module identity |

The current concentration includes:

- `bridge.brp` and `frontend_graph_typecheck.brp` request/result adapters;
- `graph/indexed_graph.brp` compatibility/materialization accessors;
- `graph/definition_identity.brp` exported, callable, and source keys;
- `graph/definition_index.brp` module-owned definition allocation and lookup;
- `graph/semantic_occurrence.brp` exported definition/reference projection;
- `headers/declaration_skeleton.brp` structural and runtime declaration IDs,
  including compiler-prelude traits;
- `modules/bound_module_graph.brp` identity/path accessors;
- `state.brp` unscoped, extensible, and reserved module states;
- `decl.brp` graph completion, body planning, diagnostics, and typed modules;
  and
- `type_system/generic_params.brp` bound trait identity.

Re-run this inventory from the Issue 56 result. The list above is context, not
permission to miss newly introduced callers.

## Current Identity Problem

`StructuralDeclarationIdRep` currently embeds:

```blorp
private record StructuralDeclarationIdRep {
	module_identity: ModuleIdentity,
	name: String,
	owner: Option[String],
	span: SourceSpan
}
```

Runtime declaration IDs then wrap this record plus a definition integer.
Callables, constructors, traits, implementations, and globals use variants of
that shape. Accepted authorities additionally retain owner module paths and
build path/name/definition indexes.

This allows standalone equality but copies a managed module identity into hot
declaration products. It also encourages APIs to accept an identity, construct
a storage key or canonical path, probe a dictionary, and recover a row that
the caller's module scope already identified.

Recent Stage 06 measurement established both sides of the tradeoff:

- unboxed owner IDs in hot type/declaration paths can remove millions of
  allocations and materially improve declaration-skeleton time; and
- retaining a managed `PreparedModuleScope` or compensating dictionary per
  declaration can erase or reverse that win.

The shared `ModuleTable` from Issue 56 removes the need for either compromise.

## Target Ownership Model

### Entity rows carry foreign keys

Graph-backed declaration/category rows carry `ModuleId`, not
`ModuleIdentity`, module path, or a graph object. Intrinsic source name, owner
relationship, span, visibility, and category facts remain only where they are
canonical for that row.

Do not retain both `ModuleId` and a materialized `ModuleIdentity` on the same
hot row after cutover.

### Owning products retain the table

Products that interpret module IDs retain the shared table once. Candidates
include `IndexedGraph`, accepted/recoverable graph facts, definition index,
and category authority tables. Choose the narrowest existing owner that
already spans all contained rows. Do not thread a generic database through
leaf functions that only compare two IDs from an already-proven domain.

### Equality is domain-aware

A bare `ModuleId` is not globally comparable. Within one opaque product whose
constructor validated one table domain, integer equality is exact. APIs that
can receive values from independent products must either:

- accept the owning product/table and validate provenance before comparison;
- materialize exact module identity at that explicit boundary; or
- be redesigned as table-owned queries so standalone cross-product equality
  is not expressible.

Do not add a managed provenance pointer to every ID merely to preserve an old
standalone equality helper. The normalized API should make invalid cross-table
comparison unavailable.

### Definition ownership is explicit

This issue may introduce the narrow owner column/table required to map an
accepted definition/category row to `ModuleId`. It must not create a second
general declaration catalog or retain another complete category payload.

Raw definition integers are not globally unique across independently
constructed graphs. Never build a global `definition_id -> ModuleId` map and
assume integer uniqueness without proving the definition domain. The rejected
Stage 06 experiment that retained old identity validation plus such a map is
negative evidence.

### Builtins and graphless programs are explicit

Compiler-prelude traits and other compiler surfaces currently construct a
`ModuleIdentity` without a frontend graph. Direct-program and anonymous
typechecking can also begin in `UnscopedModuleScope` and later create an
`ExtensibleModuleScope`.

Before changing these paths, choose one explicit representation:

1. compiler and standalone inputs construct legitimate module-table rows; or
2. a phase-specific identity variant distinguishes table-owned and
   compiler/anonymous ownership.

Prefer legitimate rows when they participate in normal module/declaration
relationships. Retain an explicit variant only when there is genuinely no
module entity. Do not use `-1`, a path hash, an empty path, or a fabricated
user module.

## Implementation Sequence

### 1. Add failing identity and ordering tests

Pin current behavior before representation edits:

- exact module ownership for every declaration category;
- same spelling in distinct modules;
- same raw definition ID in independently constructed graphs;
- duplicate callable IDs and newest-first overload/name order;
- trait/method/implementation ownership and inherited/default methods;
- constructor/type/record/union ownership and containment;
- local, selective, qualified, prelude, public, and private visibility;
- compiler builtin and compiler-surface identity;
- anonymous and direct-program typechecking;
- exact definition-ID claim order/frontier;
- accepted versus recoverable graphs; and
- exact errors, diagnostics, help text, and spans.

Add a structural test that fails if a graph-backed ID retains a managed
`ModuleIdentity`, graph, scope, or table field in generated C.

### 2. Make TypecheckState's module domain explicit

Change graph-backed reserved/extensible state to retain one module-domain owner
and current `ModuleId`. Keep lexical/session state separate. Establish the
explicit compiler-surface/direct-program path without weakening constructors.

Run the state, definition-index, and direct/replay suites before proceeding.

### 3. Migrate declaration identity families in dependency order

Use this order unless the fresh dependency graph proves a narrower one:

1. type and constructor ownership;
2. global ownership;
3. callable ownership;
4. trait and trait-method ownership;
5. implementation and implementation-method ownership; and
6. shared structural/source definition keys.

For each family:

- change owner payload to `ModuleId`;
- make the authority/table constructor validate the ID against its one module
  table;
- replace identity/path dictionary probes with table-aligned indexes where a
  real dense consumer exists;
- preserve all source and duplicate ordering;
- materialize identity only at named external boundaries;
- run focused behavior, leak, and generated-C checks; and
- delete the old owner field/accessor before moving to the next family.

Do not carry a temporary parallel owner field across the complete migration.

### 4. Normalize DefinitionIndex

Make graph-owned definition keys and rows use `ModuleId`. Preserve its exact
allocation seed/frontier, source-span discrimination, callable signature
behavior, duplicate conflicts, and compiler builtin bootstrap.

If the index needs descriptive identity only for conflicts or projection,
resolve it through the retained module table at that boundary. Do not rebuild
module identity storage keys inside ordinary table lookup.

### 5. Normalize bound and accepted graph queries

Remove remaining internal identity/path lookups from bound module selection,
header completion, body planning, module environment selection, accepted
authority owner checks, and graph diagnostics where the caller already owns a
validated `ModuleId`.

Canonical path strings remain valid source/import spelling and rendering
facts. They stop being the primary internal join key.

### 6. Preserve semantic and replay boundaries

Semantic occurrence and exported-key projection may continue returning the
current durable descriptive identity in this issue. They must obtain it from
the module table exactly once per projected module/definition boundary, not
store it on every internal occurrence.

Replay encoding similarly materializes a self-contained descriptive request
or response. Replay decoding normalizes once.

### 7. Delete obsolete APIs

Remove:

- graph-backed `*_module_identity` fields and accessors;
- storage-key helpers used only by migrated internal joins;
- identity-to-row dictionaries superseded by module-aligned tables;
- cross-product standalone equality APIs that cannot prove a table domain;
- temporary benchmark/debug projections; and
- compatibility adapters with no named external caller.

## Focused Tests

Run all Stage 06 suites owning changed modules, including:

- indexed graph and definition index;
- declaration skeleton and all header/category graphs;
- accepted alias/record/union/global/callable/trait/implementation authorities;
- module binding, visibility, and bound graph;
- state, inference context, type resolution, and prepared environments;
- global completion and body-check artifacts;
- direct/replay bridge and compiler service;
- semantic occurrence and LSP semantic-index projection; and
- compiler surface/builtin tests.

Run full Stage 06, leak, compiler sanitizer, and LSP gates before acceptance.

## Measurement Plan

Use the existing Stage 06 declaration/catalog/typecheck fixtures and production
replay. Do not create a second general profiler.

Capture exact logical counts for:

- category rows and owner edges;
- table-domain validations;
- module identity materializations;
- module identity equality/storage-key calls;
- canonical-path dictionary probes;
- dense owner-table reads;
- definition-index inserts/lookups;
- accepted authority constructions/publications; and
- semantic projections.

Synthetic dimensions must vary:

- module count and declarations per module independently;
- category mix;
- duplicate names and duplicate raw definition IDs;
- import density/topology;
- same-name cross-module declarations;
- compiler-surface/direct/anonymous construction; and
- accepted/recoverable outcomes.

Compare allocations, releases, retained objects/bytes, elapsed, retired
instructions, and peak RSS. Require exact semantic checksums and diagnostics.

Generated C must prove graph-backed owner fields are unboxed integers and that
module-table ownership appears once on the containing product rather than once
per entity.

Run at least three alternating production replay pairs against one capture.
Require byte-identical request/response hashes, allocator data, and clean
timeout/memory status.

## Acceptance Criteria

1. Every graph-backed Stage 06 module owner uses `ModuleId`.
2. No graph-backed declaration ID embeds `ModuleIdentity`, canonical path, a
   graph, a scope, or a module-table reference solely for ownership.
3. Products interpreting IDs retain one compatible `ModuleTable` domain and
   validate it at construction/admission.
4. Compiler-surface, builtin, direct, and anonymous paths have explicit valid
   ownership with no sentinel IDs.
5. Internal module joins use IDs/list addressing; descriptive materialization
   is confined to named boundaries.
6. Definition allocation, equality, duplicate policy, visibility, order,
   diagnostics, and semantic projection are exact.
7. Old fields, dictionaries, and equality adapters are deleted after cutover.
8. Generated C proves unboxed per-row ownership and no managed owner
   regression.
9. Focused, Stage 06, leak, sanitizer, and LSP gates pass.
10. Production replay is byte-identical and shows no material latency, RSS,
    instruction, or allocator regression.

The issue should produce a meaningful deterministic allocation or instruction
reduction because declaration owners are high-volume. If the cumulative result
is negative, identify and remove the regressing family rather than retaining a
parallel representation for architectural appearance.

## Stop Conditions

Stop and consult before:

- changing any shared table/ID representation from Issue 56;
- changing definition-ID claim order or category duplicate behavior;
- weakening cross-graph identity checks;
- adding a table/graph/scope reference per declaration;
- introducing a general public database/query framework;
- changing `Env` lookup or registration semantics;
- changing diagnostics, visibility, import, or publication behavior;
- carrying the migration into CTFE, Core, backend, or serialized/LSP snapshot
  representation; or
- retaining both descriptive and numeric owner fields after a category is
  migrated.
