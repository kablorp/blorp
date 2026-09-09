# Issue 58: Carry Module IDs Through CTFE And Core Lowering

**Status:** Implemented; exact transport migration with neutral production
performance

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:**

- Issue 56 establishes one compilation-owned `ModuleTable` and `ModuleId`.
- Issue 57 makes that ID the authoritative graph-backed module owner inside
  Stage 06.
- The current typechecking phase-product and demand-driven CTFE contracts
  remain semantically authoritative.

Production currently invokes Stage 07 helpers from the Stage 06 bridge while
assembling the final typed graph. This issue may normalize those internal
products in place; moving CTFE orchestration to a standalone top-level phase
requires the separately approved typechecking Phase 7 cutover and is not
implicit in this transport change.

**Blocks:** Normalized Stage 06 definition/category tables reaching later
phases, table-oriented Core declaration work, and direct LSP reuse of the
compiler's module identity spine.

## Objective

Retain the compilation module table through the typed frontend result, use
`ModuleId` rather than module path/name strings to relate CTFE programs and
contexts, and make Stage 08 Core graph preparation consume module-aligned typed
payloads and exact IDs.

This is a bounded transport and lookup migration. It deliberately keeps the
current `TypedProgram`, `TypedExpr`, `SemanticType`, `CoreProgram`, and
`CoreExpr` representations. It does not normalize all typed/Core entities or
redesign the Stage 09 pipeline.

At completion:

```text
Stage 06 accepted typed module row
  ModuleId -> typed program, import bindings, diagnostics/status

Stage 07 CTFE relations
  ModuleId / GlobalId / CallableId / ConstructorId -> exact accepted rows

Stage 08 Core graph input
  ModuleId -> TypedProgram
  callable/global/import relationships use IDs
  source/C names materialize only at explicit lowering/projection boundaries
```

## Motivation

Even after Stage 06 internal ownership uses IDs, the current output
denormalizes modules into `TypecheckedModule`:

```blorp
record TypecheckedModule {
	path: String,
	module_name: String,
	module_path: String,
	module_identity: ModuleIdentity,
	parsed_program: ParsedProgram,
	module_surface: ModuleSurface,
	semantic_program: TypedProgram,
	typed_program: TypedProgram,
	errors: List[String],
	diagnostics: List[TypecheckDiagnostic],
	import_bindings: List[ImportBinding],
	ctfe_evaluated: Bool
}
```

`TypecheckedGraph` stores a target record and module records. The top-level
pipeline immediately maps these into another `CoreLoweringInput` with target
path/name/path strings and `CoreGraphUnit` records.

Stage 07 also constructs `CtfeImportedProgram` and `CtfeContext` values keyed
or queried by canonical module paths and source names. It scans typed programs
to reconstruct functions, constructors, aliases, imports, and global
environments that the accepted frontend already resolved.

Stage 08 then builds:

```blorp
Dict[String, Dict[Int, CoreLowerCallableName]]
```

keyed first by canonical module path, prefixes module names into Core strings,
and concatenates all lowered module declarations into one `CoreProgram`.

This issue removes module denormalization and repeated path-key joins while
stopping before a broad Core arena/table rewrite.

## Required Reading And Audit

Before editing, read:

- `AGENTS.md` and the normalized compilation database roadmap;
- Issues 33-35 and the typechecking Phase 6/7 roadmap sections;
- Issues 55-57 and their final measurement evidence;
- `blorp/src/compiler/pipeline.brp`;
- `stage_06_typecheck/bridge.brp` and `decl.brp`;
- all Stage 07 files, especially `context.brp`, `globals.brp`,
  `body_dependencies.brp`, `body_worklist.brp`, `ir.brp`, and
  `materialize.brp`;
- every Stage 08 file, especially `graph_prepare.brp`, `lower.brp`,
  `flatten.brp`, and `identity.brp`;
- Stage 09 `ir.brp`, `resolve.brp`, `mono*`, `trait_resolve.brp`, and callers
  that consume module/source names; and
- compiler pipeline, CTFE, Core lowering, replay, LSP, leak, sanitizer, and
  generated-C tests.

Inventory every field and operation on:

- `TypecheckedModule` and `TypecheckedGraph`;
- `CtfeImportedProgram`, `CtfeContext`, `CtfeModuleGlobalEnv`,
  `CtfeModuleAlias`, function groups, and constructor references;
- `CoreLoweringInput` and `CoreGraphUnit`;
- `CoreLowerContext.source_module` and callable-name registries;
- `CoreResolveModuleImports` and import-binding projections;
- module prefix/flattening helpers; and
- `CoreFunction.source_module`, `CoreGlobal.source_module`, and every pass that
  reads them.

Classify each string as one of:

1. module identity/join key to replace with `ModuleId`;
2. source spelling required for diagnostics;
3. language-visible import alias/name;
4. intrinsic dispatch spelling that must be resolved once from a module row;
5. generated Core/C symbol spelling; or
6. external artifact/include path.

Do not replace classes 2-6 mechanically merely because their field name
contains `module`.

## Scope And Non-Goals

In scope:

- normalized Stage 06 typed module result keyed by `ModuleId`;
- retained shared module table through CTFE and Core graph preparation;
- CTFE module/context lookup by IDs for existing production paths;
- Stage 08 module and callable-name lookup by IDs;
- exact materialization of source/C names at named boundaries;
- deletion of duplicate module path/name/identity transport used only as join
  keys; and
- measurement of the complete Stage 06-to-08 boundary.

Out of scope:

- changing CTFE scheduling/reachability semantics;
- changing which globals are evaluated or materialized;
- interning `SemanticType` or `CtfeValue`;
- flattening `TypedProgram` or `CoreExpr` into arenas;
- changing Core pass order;
- replacing every name in `CoreType` or `CoreCallKind`;
- changing C symbol spelling or ABI;
- changing LSP snapshot storage; and
- retaining rich typecheck graph/session state after Core entry.

## Target Stage 06 Output

Replace the target-plus-list transport shape with an opaque accepted typed
compilation product that owns:

```text
ModuleTable
target ModuleId
selected ModuleId list
module-aligned typed payload table
definition/category identity tables required by CTFE/Core lowering
next generated definition frontier
analysis context and requested summaries
```

A module payload should contain only phase-specific facts, for example:

```text
semantic TypedProgram
final TypedProgram
import-binding row IDs or exact binding payload
diagnostic/outcome locator
CTFE materialization status/result locator
```

It should not repeat module path, module name, `ModuleIdentity`, parsed program,
or module surface when those are available from retained earlier tables. If a
tooling caller requires parsed/surface data, retain the relevant earlier table
in its explicit analysis product rather than copy those values into every
typed module row.

The rich graph/typecheck helper must still end before late Core begins. Keeping
small immutable identity/typed payload tables is not permission to retain
`Env`, metas, diagnostics builders, accepted authorities with no later
consumer, or body-session state.

## Target CTFE Boundary

### Module identity

Change CTFE imported-program/context relations from canonical module path keys
to `ModuleId`. Resolve import aliases through Stage 04/06 binding edges once.
Use the module table only when intrinsic selection, diagnostics, or external
rendering genuinely requires a canonical path.

### Entity identity

Prefer existing exact `GlobalId`, `CallableId`, `ConstructorId`, and
definition IDs over source-name scans. If Issue 57 has not made a category ID
safe outside its accepted authority, stop and add a narrow accepted query;
do not reconstruct an identity from name plus module path.

### Evaluation state

Keep `CtfeEnv` and evaluation stack transient. This issue may replace
module-global context lookup with a module-aligned list/table, but it must not
turn local mutable binding semantics into persistent compilation rows.

### Output

CTFE returns module/entity-keyed materialization outcomes or an aligned typed
payload update. It must not emit a second complete typed module record with
copied identity fields.

## Target Core-Lowering Boundary

### Input

Replace `CoreLoweringInput` and `CoreGraphUnit` string ownership with the
retained module table and IDs. A bounded first representation is:

```text
CoreGraphInput
  module_table
  target_module_id
  ordered_module_ids
  typed_program_by_module
  import bindings/edges by module ID
  next definition ID
```

The actual type should be opaque and validate exact table alignment.

### Callable names

Replace the outer canonical-path dictionary in the prepared callable-name
registry with a module-aligned table/list keyed by `ModuleId`. Preserve the
inner exact callable-ID mapping and source/UFCS naming rules in this issue.

Materialize a module prefix once per module row where current flattening still
requires it. Do not repeatedly escape or concatenate canonical paths per
declaration/reference.

### Module flattening

Do not redesign all Core names in this issue. Current flattening may continue
to project strings, but it must receive `ModuleId` and materialize the selected
module spelling once. Record every remaining string-owned relation for the
future Core-table roadmap.

### Import resolution

Pass module import relations by IDs as far as the existing Core resolver can
consume them. Language-visible local aliases and selected source names remain
strings. The target module of a qualified/selective import should be an ID,
not a canonical path used for another lookup.

## Implementation Sequence

### 1. Pin the current boundary

Add failing structural tests for:

- exact target/dependency module order;
- `TypecheckedModule` duplicated identity transport;
- CTFE module lookup and imported function/global/constructor selection;
- Core graph callable registry path-key construction;
- import binding target identity;
- definition-ID frontier across CTFE and Core entry; and
- one-time module prefix/name materialization.

Behavior tests must pin direct and replay typed output, CTFE results/fallbacks,
Core JSON, generated C, diagnostics, and include/link metadata.

### 2. Normalize the typed graph result

Introduce the opaque module-aligned Stage 06 output while retaining current
public result projection only where a real caller still requires it. Migrate
the top-level compiler pipeline first. Then migrate LSP/compiler-service
callers or keep an explicit semantic projection at their boundary.

Delete copied identity fields as soon as their last caller moves. Do not keep
both `TypecheckedGraph` and the normalized product alive through Core lowering.

### 3. Cut over CTFE module lookup

Migrate one CTFE relation at a time:

1. imported module selection;
2. module aliases/import bindings;
3. module global environments;
4. callable/function groups;
5. constructor references; and
6. materialized global results.

After each cut, compare exact evaluation/materialization outcomes and delete
the old path-keyed map or scan. Do not change CTFE body reachability or
fallback policy.

### 4. Cut over Core graph input

Make `pipeline.brp` pass the retained table and IDs directly. Replace
`CoreGraphUnit` identity strings and the outer callable-name path dictionary.
Keep typed payload order and Core declaration order identical.

### 5. Limit name materialization

Hoist module display/canonical/C prefix construction to one per-module
boundary. Preserve exact Core JSON and C symbols. Add counters proving that
declaration/reference width no longer multiplies module-path materialization.

### 6. Delete adapters and document remaining strings

Remove superseded `TypecheckedModule` fields, `CoreLoweringInput` fields,
`CoreGraphUnit` fields, path-key dictionaries, and compatibility helpers.
Document every remaining module/name string in Stage 07-09 by its legitimate
class from the audit.

Do not proceed into expression/type arena work.

## Tests

Required focused suites include:

- Stage 06 bridge, graph completion, accepted/recoverable body, and semantic
  projection;
- CTFE globals, context, evaluator, materialization, dependency worklist, and
  fallback paths;
- Core graph preparation, lowering, flattening, identity, import resolution,
  FFI, and list layout;
- pipeline stop/observation and direct/replay equivalence;
- generated C for cross-module direct calls, UFCS, globals, types,
  constructors, traits/impls, foreign declarations, and entrypoint;
- source-package/std/native/compiler-surface modules;
- same-name modules from distinct origins and same-name declarations across
  modules;
- repeated/selective/qualified/prelude imports;
- CTFE accepted, unavailable, runtime-fallback, recursive, and failure cases;
- exact diagnostics/help/spans and definition-ID frontier;
- LSP semantic projection from the normalized typed result;
- leak and sanitizer suites; and
- release/debug/profile modes where module naming differs.

Core JSON and emitted C must be byte-identical unless the issue explicitly
proves that a non-semantic deterministic order/spelling change is required and
the maintainer approves it before implementation.

## Measurement

Use existing typecheck, CTFE, Core graph construction, and whole-compiler
profiles. Add compact counters only where an existing observation record can
own them.

Record:

- typed module rows and module table reads;
- copied/materialized module identities, paths, and names;
- CTFE imported programs scanned;
- CTFE module path/name dictionary builds and probes;
- exact callable/global/constructor ID lookups;
- `CoreGraphUnit`/lowering input records created;
- callable registry outer index entries and probes;
- module-prefix/UFCS-name constructions;
- Core declarations and calls lowered;
- allocations, releases, retained objects/bytes, elapsed, instructions, and
  peak RSS; and
- exact semantic/typed/Core/C checksums.

Synthetic matrices should independently vary:

- module count;
- declarations/callables/globals per module;
- import fan-out and density;
- CTFE-reachable versus irrelevant width;
- callable/global reference count;
- same-name cross-module declarations; and
- target/dependency selection.

Require at least three alternating baseline/candidate production self-check or
replay pairs using one capture and byte-identical responses. Because this issue
changes object lifetime across phases, allocator, retained-object/byte, and
peak RSS data are mandatory.

Generated C inspection must prove:

- `ModuleId` remains unboxed;
- one shared module table is retained by the phase product;
- no table/graph reference is retained per typed/Core entity;
- the outer callable registry is list/table addressed by module ID; and
- module prefix/path materialization occurs once per module boundary rather
  than once per declaration/reference.

## Acceptance Criteria

1. The Stage 06 accepted output retains the same compilation `ModuleTable` and
   uses `ModuleId` for target/module ownership.
2. Module-aligned typed payloads no longer duplicate identity/path/name fields
   solely for joining later phases.
3. CTFE production module relations use IDs; path/name materialization is
   confined to intrinsics, diagnostics, or external presentation.
4. Core graph preparation consumes module IDs and an aligned typed payload
   table.
5. The outer callable-name/import module relation is no longer keyed by
   canonical path strings.
6. CTFE scheduling, evaluation, fallback, materialization, Core declaration
   order, definition allocation, diagnostics, Core JSON, and generated C are
   exact.
7. No rich typecheck state is retained after its last consumer.
8. No broad typed-expression or Core-expression arena/table rewrite is
   included.
9. Focused, compiler, leak, sanitizer, LSP, and generated-C gates pass.
10. The cumulative Issues 56-58 result shows a repeatable reduction in module
    identity/path work and no material elapsed, instruction, allocator, or RSS
    regression.

If CTFE or Core cutover adds indirection without retiring a represented scan,
dictionary, or materialization, remove that subcut before acceptance and
record it as negative evidence.

## Implementation Result

The completed change carries the Issue 56 `ModuleTable` through the accepted
Stage 06 result and replaces copied module identity, path, and name fields on
`TypecheckedModule` with one `ModuleId`. Direct and rejected single-module
typecheck entry points create a legitimate one-row table rather than using a
sentinel ID. Lint and LSP callers materialize descriptive identity only at
their projection boundaries.

Stage 07 now uses IDs for imported programs, import targets, global-environment
rows, callable groups, active/target module ownership, body worklist ownership,
and CTFE IR call/global relations. Dependency traversal, target reachability,
and reusable-artifact membership use dense Boolean lists indexed by `ModuleId`;
they no longer convert IDs back to paths for string membership probes after
the Stage 04 resolution boundary. The CTFE context retains one shared module
table, and module global environments are aligned to that table. Imported CTFE
programs carry their issuing table as an admission witness. Context assembly
and global-environment updates reject IDs from a different identity-row domain
before an ID can index a dense row.

Stage 08 receives `CoreGraphUnit(module_id, typed_program)` rows. Its prepared
callable-name registry has one outer list entry per module-table row and retains
the inner callable-ID dictionary. The module prefix is materialized once before
walking each typed module's declarations. One opaque `CoreGraphModules` phase
product carries the issuing table for the complete unit list; Core preparation
rejects a product issued by another table before any unit is lowered. The
top-level Core lowering input retains one table and an unboxed target ID.

Single-module source checking and graph-valued rejection results use one-row
module tables so they participate in the same ID contract. Rejected JSON and
stream responses that do not return a graph project their source and typed
fields directly and do not allocate and discard a table.

The LSP compiler service resolves each requested `ResolvedModuleIdentity` to
one `ModuleId` through the graph's retained table, then selects and excludes
typed modules with integer comparisons. Descriptive `ModuleIdentity` remains
only in the LSP artifact fingerprint consistency check and semantic-index
projection, where path and origin are part of the external identity contract.

The existing `TypecheckedGraph` target-plus-selected-modules shape remains
because its ordering and partial target projections are public compiler/LSP
contracts. Its module rows now own IDs and no copied join spelling. Likewise,
`parsed_program` and `module_surface` remain because lint, diagnostics, and LSP
projection consume their source-faithful facts; they are not used as module
join keys. Introducing a second dense payload wrapper solely to restate this
selection would add ownership and indirection without retiring measured work.

### Remaining string classification

| Remaining value | Classification | Boundary |
| --- | --- | --- |
| parsed source path and module name | source spelling / diagnostics | retained parsed program |
| selective names and qualified aliases | language-visible spelling | import binding payload |
| intrinsic module path | intrinsic dispatch spelling | materialized from `ModuleTable` in CTFE evaluation |
| resolved-call module path in `TypedExpr` | retained typed semantic metadata | converted to `ModuleId` at each Stage 07 IR or Stage 08 expression-lowering boundary |
| Core module prefix, flattened names, C symbols | generated external spelling | materialized once per module lowering boundary |
| include directories and foreign link values | external artifact path | pipeline and FFI boundary |
| Stage 09 resolver module-import descriptions | later-phase descriptive metadata | explicitly outside Issue 58 |

Changing `TypedExpr`, Stage 09 IR, or LSP snapshot representations remains out
of scope. No `Env`, inference meta, CTFE evaluation stack, or other rich
typecheck session state is retained across the Core boundary.

At Issue 58 completion, imported and trait call expressions still carried only
canonical-path metadata and performed a path-to-ID probe when entering CTFE IR
or Core lowering. [Issue 61](61-carry-module-ids-in-resolved-call-metadata.md)
owns that explicit typed-expression metadata follow-up; it does not change the
scope or measurements reported here.

## Measurement Result

All raw measurement artifacts are ignored under `logs/issue58/`. The baseline
and candidate were built serially from the same source tree and bootstrap; the
candidate production patch SHA-256 was
`fee0467c7e2fa8efcf246f41f21ec5bf4557ead6b7fc95524dd67e90d9d11280`.
The identical benchmark-only allocator patch SHA-256 was
`a1462edb642d58c25364050ca051c2d56a284df979d0dc54b9f3bc92998e2aef`.
Worker SHA-256 values were
`bf4ce0615b2d6d0f8c26f02a88ef8e1e317e8bc57ce53bd290d199cc24355cac`
for baseline and
`67ee85de82debe7e50f78b66e4440ed3115636949f65a39c097001e3e74a955f`
for candidate.

### Focused CTFE matrix

The matrix ran three paired samples for retained and eager-fallback modes at
1, 8, and 32 modules and 1, 16, and 64 functions per module: 108 measured
rows. Every row was valid, error-free, and exactly equal for artifact,
declaration, CTFE body/import/evaluation, and semantic checksum fields.

The candidate added 6 allocations at one module, 31 at eight modules, and 107
at 32 modules, independent of function width and retained/fallback mode. Every
added allocation had a matching release; both variants ended at one live
object and 64 live bytes. Elapsed medians ranged from -13.98% to +13.39% with
no stable direction in the original clean run; the final post-review rerun was
timing-contended and is not used as elapsed evidence. The small O(module-count)
allocation cost is the price of the dense ID-aligned context, membership rows,
and explicit imported-program provenance; it does not scale with declarations.

Final raw rows are in `logs/issue58/ctfe-final/raw.txt`; deterministic medians
are in `logs/issue58/ctfe-final/summary.tsv`.

### Core graph preparation

A temporary ignored fixture constructs the complete typed graph before the
measurement window, selects every dependency module, invokes the real
`prepare_core_graph` production boundary once, and computes a deterministic
checksum from Core JSON after allocator capture. Three paired baseline/candidate
runs independently varied 1, 8, and 32 modules against 1, 16, and 64 functions
per module: 54 rows. Every pair had identical Core bytes, Core checksum, and
next-definition frontier. The ignored baseline and candidate fixture source
SHA-256 values were
`ed3bec9699029602255e5cea881b21a9b5fee98c120f4fc468188e13b516133a`
and
`4984bbf77ac8cb2898a5a7f3e4d03e402ac0ac6a2bde4c3945f49ea16afaf66e`.

| Modules x functions | Baseline allocations | Candidate allocations | Delta | Elapsed median delta |
| --- | ---: | ---: | ---: | ---: |
| 1 x 1 | 308 | 312 | +4 | +8.33% |
| 1 x 64 | 8,079 | 8,020 | -59 | -4.17% |
| 8 x 1 | 1,873 | 1,879 | +6 | +2.46% |
| 8 x 64 | 91,343 | 90,845 | -498 | -1.04% |
| 32 x 1 | 7,231 | 7,239 | +8 | +0.52% |
| 32 x 64 | 376,805 | 374,797 | -2,008 | -1.95% |

Releases changed by the same amount as allocations; retained objects and bytes
were identical in every pair. The low-width +4 to +8 cost is the one table-
provenance product plus dense outer-list setup. Once callable width is present,
retiring the canonical-path-keyed outer dictionary removes allocation work
proportional to declarations. Spotlight indexing was active during this final
matrix, so elapsed values are directional only and allocator/checksum fields
are the acceptance evidence. Raw and summary rows are in
`logs/issue58/core-graph-final/raw.txt` and
`logs/issue58/core-graph-final/summary.tsv`.

### Production typecheck replay

One warmup per worker and three alternating measured pairs used the existing
target-only typecheck replay with allocator statistics and no inventory. The
11,690,583 byte capture SHA-256 was
`de93c30a153c0e60a75c3fdb548866d08eb76ebab1721266d5b16f8ddb539b4c`.
Every run was verified with request SHA-256
`5eabbc7bafad8b070b8d9d2ff13c71bb5b5f4760cb0989c2827c00b0a5843c6b`
and byte-identical 1,755,080 byte responses with SHA-256
`f11d97d6f1cf5ac91ae76d1461ded8ba5a8884f1217504621bf3707d75363851`.

| Metric | Baseline median (range) | Candidate median (range) | Delta |
| --- | ---: | ---: | ---: |
| elapsed seconds | 8.102259 (8.072719-8.112202) | 8.095897 (8.086054-8.108651) | -0.08% |
| peak RSS bytes | 504,463,360 (504,446,976-504,463,360) | 504,397,824 (504,381,440-504,397,824) | -65,536 (-0.01%) |
| allocations | 58,062,714 | 58,062,884 | +170 (+0.0003%) |
| releases | 52,830,448 | 52,830,620 | +172 (+0.0003%) |
| current objects | 5,232,266 | 5,232,264 | -2 |
| live bytes | 471,463,712 | 471,463,584 | -128 |

Checkpoint medians changed by +0.19% for graph parse, -0.50% for declaration
skeleton, +0.84% for graph preparation, -0.08% for body typecheck, and -0.16%
for projection. These values are below a defensible production signal. The
final replay ran while unrelated macOS indexing/media services were active, so
its elapsed values corroborate but do not replace the earlier clean replay's
neutral result. Allocator counts and exact response identity are deterministic.
This target-only replay exercises the normalized Stage 06 and CTFE result path
but does not execute Stage 08; the separate production-boundary matrix above
covers Stage 08.

Raw final replay JSON and deterministic summaries are in
`logs/issue58/replay-final/`.

### Generated C

The final generated compiler C SHA-256 is
`32cd06ee26fd79e2d2257edd082d07a2000d7d391bee682381782b4a0c3a91fd`.
Inspection confirms:

- `ModuleId` fields in `TypecheckedModule`, `CtfeContext`, `CoreGraphUnit`, and
  the Core lowering input are emitted as unboxed `long` values;
- `TypecheckedGraph`, `CtfeContext`, and the Core callable registry retain one
  shared module-table pointer, not one pointer per typed/Core entity;
- `TypecheckedModule` has no copied identity/path/name fields;
- `CoreGraphUnit` contains only the unboxed module ID and typed-program
  pointer;
- the callable registry outer index is a module-count-sized `List` indexed by
  module ID; and
- module-prefix construction occurs before the declaration loop, once per
  typed module.

The generated CTFE profile C SHA-256 is
`7fa7411e5e71d5392fb8df879c2e4d64940842b21c4a223e9bd722e33f1c1346`.

The isolated worktree paths initially used hyphens; the existing generated-C
symbol/path handling does not sanitize hyphens in absolute source roots. The
measurement worktrees were moved to underscore-only paths. This is a harness
path limitation, not a semantic difference between variants.

## Conclusion

Issue 58 retires copied module identity fields, path-keyed CTFE relations, and
the outer path-keyed Core callable registry. It preserves exact behavior and
has neutral whole-compiler allocator/RSS cost, but it does not produce a
measurable compiler-wide speedup by itself. Proceed to Horizon 2 only as a
measured consumer of this single ID spine; do not attribute a speedup to this
transport change or reintroduce a parallel descriptive module authority.

## Stop Conditions

Stop and consult before:

- changing the ModuleTable/ModuleId contract from Issues 56-57;
- changing CTFE reachability, evaluation, fallback, or materialization
  semantics;
- changing Core pass order or C ABI/name spelling;
- retaining all Stage 06 environments or typed graphs through late Core;
- flattening typed/Core expression trees into IDs;
- interning mutable or unresolved semantic types;
- introducing a generic database parameter throughout Stage 07-09;
- changing LSP snapshot/revision behavior; or
- broadening into Stage 09 table-native passes.
