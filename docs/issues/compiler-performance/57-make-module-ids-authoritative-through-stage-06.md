# Issue 57: Make Module IDs Authoritative Through Stage 06

**Status:** Completed

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

### Issue 56 result audit

The pre-edit audit on `c4aae8b0` found 77 explicit `ModuleIdentity` or
`ResolvedModuleIdentity` type tokens, 90 identity-helper calls, and 812
`module_path`, `module_name`, or `canonical_path` tokens under Stage 06. The
broader inventory contained 1,026 matching lines. Every explicit descriptive
identity use is confined to the following eleven files:

| File | Classification and required action |
| --- | --- |
| `bridge.brp` | Replay/compiler-surface decoding and result projection. Normalize once on entry and retain descriptive serialization. |
| `frontend_graph_typecheck.brp` | Stage 04 request selection and compatibility projection. Retain resolved identities only at the external request boundary; pass IDs after admission. |
| `graph/indexed_graph.brp` | Compatibility materialization from the shared table. Retain named identity accessors only for diagnostics/replay and remove internal callers. |
| `graph/definition_identity.brp` | `FuncCallableKey` and `SourceDefinitionKey` are graph owner rows and migrate to `ModuleId`; `ExportedSymbolKey` remains a descriptive semantic/LSP boundary. |
| `graph/definition_index.brp` | Graph owner keys and string module buckets migrate to the shared table and dense module-aligned buckets. Trait import spelling remains source syntax. |
| `headers/declaration_skeleton.brp` | Every graph declaration owner migrates to `ModuleId`. Compiler builtin traits require an explicit non-graph representation, not a sentinel. |
| `modules/bound_module_graph.brp` | Internal selection migrates to existing ID positions. Descriptive identity remains only in rejected-binding diagnostics and compatibility projection. |
| `state.brp` | Reserved graph state already owns `PreparedModuleScope`; internal claims migrate to its ID. Direct/anonymous state remains an explicit graphless domain until scoped. |
| `decl.brp` | Internal owner comparisons and selections migrate to IDs. Typed-module, diagnostic, and exported semantic construction materialize through the owning graph. |
| `graph/semantic_occurrence.brp` | Per-module durable semantic/LSP projection remains descriptive; leaf occurrences continue not to repeat module identity. |
| `type_system/generic_params.brp` | Bound trait ownership is graph-backed and must migrate, while source-rendered bound names remain spelling. |

The other 812 path/name tokens were classified by caller. Import declarations,
qualified aliases, visibility projections, module-view keys, source spans,
diagnostic text, builtin manifest names, and semantic type spellings are
genuine source or external projection facts and remain strings. Owner paths in
accepted callable/global/trait/implementation authorities are transitional
internal joins and migrate only where their constructor already owns the bound
graph; no path is reinterpreted heuristically as an ID.

The baseline before representation edits is green: definition-index suites
`7/7`, `13/13`, and `8/8`; declaration skeletons `12/12`; typecheck state
`19/19`; structural checks `26/26`. Three new structural assertions then fail
on the current descriptive declaration owner, descriptive internal definition
keys, and string-keyed definition-index module buckets, establishing the TDD
boundary.

## Implementation Result

Stage 06 now uses the Issue 56 `ModuleId` domain as the owner representation
for graph-backed definition keys, declaration IDs, typecheck state, definition
index rows, and accepted callable/global/trait/implementation authority rows.
The containing products retain the shared `ModuleTable`; their entity rows do
not. Constructors validate that incoming IDs were allocated by the product's
table before storing them.

Accepted callable, global, trait, and implementation rows do not retain a
second owner-path field. Localization, visibility, and diagnostic projections
materialize the canonical path from the row's ID and the authority's shared
table. Exact bound-graph and accepted-authority queries require the table that
issued the incoming ID and reject incompatible allocation domains; equal dense
row numbers from separate compilations are not interchangeable. The former
general declaration-skeleton exact-ID accessor was used only by tests and was
removed rather than leaving a raw-ID boundary without a domain witness.

The resulting data flow is:

```text
IndexedGraph(ModuleTable)
  -> PreparedModuleScope(ModuleId)
  -> TypecheckState(ModuleId, DefinitionIndex)
  -> declaration/category rows(ModuleId)
  -> identity materialization at diagnostic, replay, typed-module,
     or semantic-occurrence projection boundaries
```

`DefinitionIndex` now owns the table and dense per-module buckets. Its public
construction is fail-closed when a scope or key belongs to an incompatible ID
domain. `IndexedGraph` and accepted authorities reuse the same table rather
than reconstructing path/identity maps. Definition allocation order and the
raw definition-ID frontier are unchanged.

`TraitId` uses an explicit builtin variant for compiler-provided traits. Direct
and anonymous typecheck sessions remain an explicit graphless state: they
retain descriptive `ModuleIdentity` only until an extensible scope is formed,
then obtain the legitimate `ModuleId` owned by their `DefinitionIndex`. No
sentinel ID or fabricated user module was introduced.

`bound_module_graph_modules_for_prepared` remains one explicit normalization
boundary for replay and CTFE requests. Its input is the Stage 04
`PreparedModule` product, which intentionally has no `ModuleId`; the boundary
matches that descriptive Stage 04 identity against the already-owned Stage 06
graph and returns graph-owned `BoundModule` rows. No descriptive identity is
carried past that admission step or used for an internal Stage 06 join.

Direct graphless sessions retain their display module name separately from the
synthetic table's storage key. Definition-conflict diagnostics therefore keep
the source-facing name while graph-backed diagnostics continue to materialize
their canonical path from the shared table.

The first ownership gate exposed an existing one-object-per-state leak in the
opaque `DefinitionIndexSeed`. Its representation was a private one-field
struct, which generated an untagged 32-byte `blorp_box_struct` allocation that
the `UnscopedModuleScope` destructor could not release. The seed is now an
opaque scalar `Int`. This keeps the constructor private and removes the box;
the full leak gate subsequently passed `885/885` with zero leaked bytes.

### Remaining descriptive identities

The post-migration Stage 06 inventory has 87 matching lines for
`ModuleIdentity`, `ResolvedModuleIdentity`, or `module_identity_*`, distributed
as follows:

| Area | Lines | Retained boundary |
| --- | ---: | --- |
| `state.brp` | 20 | Explicit graphless/direct-session ownership and descriptive accessors |
| `frontend_graph_typecheck.brp` | 16 | Stage 04 request admission and external result compatibility |
| `bridge.brp` | 12 | Self-contained replay decode/encode |
| `graph/semantic_occurrence.brp` | 11 | Durable semantic/LSP projection |
| `graph/indexed_graph.brp` | 8 | Named materialization accessors backed by `ModuleTable` |
| `graph/definition_identity.brp` | 8 | Descriptive exported semantic keys only |
| `modules/bound_module_graph.brp` | 7 | Rejected-binding diagnostics and compatibility projection |
| `modules/module_binding.brp` | 3 | Source/import identity facts |
| `decl.brp` | 2 | Typed-module/output projection |

None is a graph-backed entity owner. The broader path/name inventory remains
large because import spellings, qualified aliases, diagnostics, semantic type
names, module surfaces, and replay/LSP values are intentionally descriptive.

## Measurement Result

Raw artifacts are ignored under `logs/issue57/final-refresh-2/`. The final generated C is
`logs/issue57/final-refresh-2/generated-c/compiler_typecheck_phase_profile.c`
with SHA-256
`bcbff3c3bbcd434c29b871bcf6c90571115eec78a68efff4bbad3be848006625`.
It shows `long module_id` in `FuncCallableKeyRep`,
`SourceDefinitionKeyRep`, and `StructuralDeclarationIdRep`; no entity row owns
a module table, graph, scope, or materialized module identity. The final C has
no `DefinitionIndexSeedRep` or seed boxing call.

### Synthetic Stage 06 matrix

The parent tree was a detached `c4aae8b0` worktree and the candidate was the
final Issue 57 source tree. Both benchmark programs were compiled by the same
compiler, then run in alternating parent/candidate order with the existing
`compiler_typecheck_phase_profile` accepted-graph workload. The matrix held
probes at 64, fan-out at 4, and type-bearing modules at 100%, while varying
module count and declarations per module independently. Every pair had exact
primary/secondary counts and semantic checksum equality.

| Modules | Declarations/module | Parent allocations | Candidate allocations | Allocation delta | Parent window (us) | Candidate window (us) | Window delta |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 16 | 25,578 | 24,728 | -3.32% | 74,712 | 46,640 | -37.57% |
| 8 | 1 | 87,631 | 81,459 | -7.04% | 318,083 | 249,990 | -21.41% |
| 8 | 16 | 206,718 | 200,546 | -2.99% | 657,191 | 410,150 | -37.59% |
| 8 | 64 | 829,357 | 823,185 | -0.74% | 3,161,256 | 1,395,013 | -55.87% |
| 32 | 16 | 936,745 | 912,141 | -2.63% | 2,899,058 | 2,012,174 | -30.59% |

Two additional alternating `8 x 16` pairs reproduced the result. Across three
samples, the parent window median was 663,068 us and the candidate median was
414,433 us (`-37.50%`). Allocations were deterministic at 206,718 versus
200,546 (`-6,172`), with retained objects 61,806 versus 61,760 and allocated
bytes 4,539,880 versus 4,533,800. This is focused Stage 06 evidence, not a
compiler-wide speedup claim.

### Production typecheck replay

The production capture is 11,661,656 bytes with SHA-256
`44fc4314518f3e18bd720da4077dbeb2323e2cc73569aa1e6a684d480c46c2b5`.
The parent Issue 56 worker is
`35af9fffb20cc6f9937539437a55e90f1710101f459259606eb9989844f8eb80`;
the final candidate worker is
`4380b6f26c4bf0f7d629db80a8865bca69b9f18c961abc279f06bd48eda344ef`.
After one warmup per worker, three serial alternating pairs all reported
`verified=true`, allocator stats available, exit 0, no timeout or memory-limit
failure, and the same 1,755,080-byte response SHA-256
`5b7dbfd8d0e9df52c8f9114a1563cb913c30a0dc0c4f1847743a78c798dd1da9`.

| Metric | Parent median (range) | Candidate median (range) | Delta |
| --- | ---: | ---: | ---: |
| Elapsed seconds | 8.224 (8.199-8.390) | 8.211 (8.208-8.226) | -0.16% |
| Peak RSS bytes | 504,381,440 (504,102,912-504,938,496) | 503,234,560 (503,234,560-503,398,400) | -1,146,880 |
| Allocations | 58,801,457 | 57,952,252 | -849,205 (-1.44%) |
| Releases | 53,590,183 | 52,741,437 | -848,746 |
| Current objects | 5,211,274 | 5,210,815 | -459 |
| Allocated bytes | 470,248,976 | 469,707,008 | -541,968 |

Median parent/candidate checkpoints were 2,525,176/2,520,413 us for graph
parsing, 2,939,406/2,931,942 us for declaration skeletons,
1,816,885/1,824,705 us for graph preparation, 11,674/10,359 us for target body
typecheck, and 62,524/62,105 us for projection. These sampled phase timings are
diagnostic; the exact allocation counts and byte-identical response are the
primary production evidence.

The existing replay harness does not expose retired hardware instructions, so
no instruction count is claimed. The exact allocator reduction and focused
window result provide the deterministic performance evidence; production wall
time and sampled RSS are positive but near noise.

## Validation Result

- `scripts/compiler-check --changed`: 22 production sources, 31 focused
  suites, and 2 structural checks passed.
- Independent `scripts/compiler-check --stage typecheck`: 44 production
  sources, 34 focused suites, and 2 structural checks passed.
- Full leak gate: `885/885`, zero failures and zero leaked bytes.
- Compiler sanitizer gate: `3,584/3,584` under ASan and UBSan.
- LSP gate: `36/36`; the one reported skip is the suite's intentional platform
  skip.
- Definition index/identity/reservation suites: `8/8`, `13/13`, and `8/8`.
- Declaration catalog, typecheck declaration, and state suites: `19/19`,
  `126/126`, and `19/19`.
- Inference, bridge, and LSP semantic projection suites: `304/304`, `110/110`,
  and `16/16`.
- Final generated-C structural inspection passed as described above.
- `git diff --check` and formatting checks passed.
- Correctness re-review and independent test-runner review both approved with
  no remaining findings.

The result satisfies the intended Stage 06 ownership cutover and is suitable
for Issue 58. Follow-on work should use the dense owner/category relations now
available; it should not reintroduce descriptive owner fields for convenience.

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
