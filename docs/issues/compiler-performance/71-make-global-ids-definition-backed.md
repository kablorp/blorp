# Issue 71: Make Global IDs Definition-Backed

**Status:** Implemented

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependency:** Issue 61B must publish `GlobalDefinition` rows in the canonical
graph `DefinitionTable`.

**Can proceed independently of:** Issues 69-70 after Issue 68, subject to
sequential integration through shared declaration-skeleton and projection
files.

**Blocks:** The final declaration-relation cleanup in Issue 73.

## Objective

Replace the managed structural `GlobalId` with a category-checked, unboxed ID
backed by the already reserved `GlobalDefinition` row. Cut completed-global,
accepted-global, module-view, typed-reference, CTFE, and semantic-projection
consumers over in the same issue.

The completed relationship is:

```text
GlobalId -> DefinitionId -> DefinitionRow {
  module_id,
  kind = GlobalDefinition,
  name,
  span
}
```

Remove duplicate raw definition IDs and module/name/span identity from global
payloads where `GlobalId` answers the same question. Source-name indexes remain
valid only for queries that begin with unresolved source spelling.

## Current Production Shape

`declaration_skeleton.brp` currently defines:

```blorp
private record StructuralDeclarationIdRep {
	module_id: ModuleId,
	name: String,
	owner: Option[String],
	span: SourceSpan
}

opaque type GlobalId = StructuralDeclarationIdRep
```

Yet `DefinitionIndex` already reserves a `GlobalDefinition` for every parsed
module global. Skeleton construction ignores that reserved integer and creates
another identity from module/name/span.

`AcceptedGlobalBinding` then carries both forms incompletely:

```blorp
record AcceptedGlobalBinding {
	id: GlobalId,
	binding_type: SemanticType,
	source_type: Option[SemanticType],
	is_mutable: Bool,
	definition_id: Option[Int]
}
```

`AcceptedGlobalTable` owns the shared module table but indexes exact global
identity by `module index + source name`, even when a resolved `GlobalId` is
already available:

```blorp
private record AcceptedGlobalTableRep {
	module_table: ModuleTable,
	slots: List[AcceptedGlobalSlot],
	indices_by_module_and_name: List[Dict[String, Int]]
}
```

That representation makes exact global lookup perform descriptive extraction
and a string dictionary probe. Other global dependency, initializer,
occurrence, and CTFE structures also mix `GlobalId`, raw `Int`, and module/name
identity.

## Required Reading And Audit

Before editing, read:

- Issue 61B's final definition-domain and provenance decision;
- global reservation in `graph/definition_index.brp`;
- global construction/accessors in `headers/declaration_skeleton.brp`;
- `headers/global_header_completion.brp`;
- `type_system/accepted_global_authority.brp`;
- all global declaration/body handling in `decl.brp` and `infer.brp`;
- Stage 07 global context, dependency, evaluation, and materialization files;
- Stage 08 global lowering;
- `graph/semantic_occurrence.brp` and typed-AST JSON;
- module views/import bindings that expose globals; and
- global completion, authority, CTFE, replay, LSP, leak, sanitizer, and profile
  tests.

Inventory every field or argument named `global_id`, `definition_id`,
`module_path`, `original_name`, and `owner_module_path` in a global-owned type.
Classify it as:

1. exact graph identity;
2. runtime/Core definition integer boundary;
3. unresolved source-name lookup key;
4. language-visible imported alias/original spelling;
5. diagnostic/protocol projection; or
6. CTFE transient state.

Do not remove classes 3-6 mechanically. Do not keep classes 1-2 duplicated in
every accepted global binding.

## Target ID And Table APIs

Make `GlobalId` a scalar wrapper validated once:

```blorp
opaque type GlobalId = DefinitionId

pure func definition_table_global_id(
	table: DefinitionTable,
	definition_id: DefinitionId,
) -> Option[GlobalId]

pure func global_id_definition_id(id: GlobalId) -> DefinitionId
```

Descriptive facts come from the table:

```blorp
pure func definition_table_global_module_id(
	table: DefinitionTable,
	id: GlobalId,
) -> Option[ModuleId]

pure func definition_table_global_name(
	table: DefinitionTable,
	id: GlobalId,
) -> Option[String]
```

There must be no public unchecked `GlobalId` constructor. Inside a coherent
opaque product, equality is integer equality. Cross-product admission validates
the issuing definition/module tables once.

## Skeleton And Completion Cutover

Global skeleton construction must claim the row that Issue 68 reserved:

```blorp
key = source_definition_key(
	context.module_id,
	GlobalDefinition,
	var_decl.name.text,
	None,
	var_decl.span,
)
definition_id ?= definition_index_find_source_definition_id(
	context.definition_index,
	context.module_table,
	key,
)
global_id ?= definition_table_global_id(context.definitions, definition_id)
```

Missing or wrong-kind rows are internal phase-product errors. Do not fall back
to reconstructing `GlobalId` from the parsed declaration.

Global completion dependencies should use `GlobalId` and `CallableId` at their
typed boundaries. Algorithms may use the unboxed underlying integer as a
dictionary key through a narrow accessor, but public records must not revert to
raw `Int` identity.

Preserve:

- source-order allocation;
- annotated versus inferred global completion;
- strongly connected component scheduling;
- accepted versus rejected outcomes;
- dependency and diagnostic order; and
- the final generated-definition frontier.

## Accepted Global Authority Cutover

An accepted binding should not carry a second optional definition integer when
its exact ID already names that definition:

```blorp
record AcceptedGlobalBinding {
	id: GlobalId,
	binding_type: SemanticType,
	source_type: Option[SemanticType],
	is_mutable: Bool
}
```

If `definition_id: None` currently represents a legitimate builtin,
provisional, lexical, or recovery state, do not erase that distinction. Split
the non-graph state into an explicit variant outside `AcceptedGlobalBinding`;
accepted graph globals must always have a valid `GlobalId`.

For resolved-ID lookup, index by the unboxed global definition ID or direct
slot:

```blorp
private record AcceptedGlobalTableRep {
	definition_table: DefinitionTable,
	slots: List[AcceptedGlobalSlot],
	index_by_global_id: Dict[Int, Int],
	indices_by_module_and_source_name: List[Dict[String, Int]]
}
```

The second index is illustrative and should remain only for actual source-name
queries. Do not retain it merely because the old exact-ID lookup used it.

Module views may continue mapping a source spelling to a compact global
locator. Their values must not repeat the owner path and original name when
those facts are already in the definition table or import binding. Keep
language-visible aliases where the user wrote a different local name.

## CTFE And Core Boundaries

Stage 07 already uses module IDs for global contexts, but some structures carry
raw global definition integers or source names. Convert graph identity to
`GlobalId`; keep source name only for diagnostics, intrinsic classification, or
name lookup that genuinely begins from syntax.

When Core still requires the historical raw definition integer, project it
once:

```blorp
core_definition_id = definition_id_runtime_value(
	global_id_definition_id(global_id),
)
```

Do not change Core definition numbering, C names, CTFE reachability, evaluation,
fallback, or materialization semantics in this issue.

## Scope

In scope:

- definition-backed, unboxed graph `GlobalId`;
- claiming the reserved global row during skeleton construction;
- global header completion and dependency IDs;
- accepted global table exact-ID indexes;
- removal of duplicate optional raw definition identity from accepted graph
  bindings;
- ID/locator-only global module views where possible;
- CTFE, Core-lowering, typed-AST, semantic occurrence, and LSP projections; and
- deletion of structural global identity helpers and obsolete indexes.

Out of scope:

- changing global dependency scheduling or initialization semantics;
- changing callable or type identity;
- changing CTFE evaluation/materialization behavior;
- changing Core IDs, names, or ABI;
- normalizing local variables or body environments;
- interning semantic types;
- adding caches/invalidation; and
- changing external JSON/LSP schemas.

## Implementation Sequence

### 1. Pin current global semantics and work

Add a failing test that proves a reserved global definition can be retrieved by
ID and that `GlobalId` does not need module/name/span storage. Record current
exact-ID versus source-name lookup counts in a production-shaped global
authority fixture.

### 2. Claim scalar IDs in declaration skeletons

Change the skeleton constructor and ID accessors. Convert header completion and
declaration graph APIs until all global identities are typed. Delete the
structural `GlobalId` constructor immediately.

### 3. Cut over accepted authority

Retain `DefinitionTable` once in the accepted table or its containing graph.
Use integer exact-ID lookup. Keep only source-name indexes with production
readers. Remove the duplicate optional definition ID from accepted graph rows.

### 4. Cut over CTFE and projection readers

Convert dependencies, initializers, semantic occurrences, typed JSON, and Core
lowering. Materialize module path/name/span only at output/diagnostic boundaries.

### 5. Delete residue and measure

Delete structural equality/accessors, redundant owner paths, raw-ID adapters,
and tests that fabricate impossible accepted global states. Report production
and test diffstats separately.

## TDD And Fast Feedback Loop

Iterate with the exact current manifest owners. At minimum:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_bridge.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_ir.brp
scripts/compiler-check --changed
```

Then run:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Inspect generated C and confirm:

- `GlobalId` is an unboxed integer;
- global exact lookup does not extract/compare module/name/span;
- accepted graph bindings do not contain a duplicate optional raw definition
  integer;
- no table pointer is retained per global ID or binding; and
- source-name dictionaries remain only where a source-name query uses them.

## Performance Harness

Use `compiler_typecheck_phase_profile` and a narrowly extended
`compiler_frontend_declaration_catalog_profile`/accepted-global fixture. Vary:

- module count;
- globals per module;
- annotated versus inferred globals;
- dependency edge density and cycles;
- repeated source names across modules;
- resolved-ID lookup count; and
- selective/qualified visible source-name lookup count.

Record exact global rows, dependency edges, structural IDs constructed/copied,
definition-row reads, string and integer probes, candidates visited,
allocations/releases, retained bytes, frontier, and semantic checksum.

The expected focused win is integer exact lookup plus removal of managed
identity copies and duplicate raw-ID fields. Require fewer allocations or
retired instructions in a global-heavy exercised shape and no repeatable Phase
01-06 latency or peak-memory regression.

## Acceptance Criteria

- Every accepted graph global has one category-checked `GlobalId` backed by its
  existing `GlobalDefinition` row.
- `GlobalId` is unboxed and carries no module/name/span/table pointer.
- Global skeleton construction claims the reserved row and cannot fabricate a
  fallback structural ID.
- Accepted graph bindings do not retain a duplicate optional raw definition ID.
- Exact global lookup uses integer ID addressing; source-name indexes remain
  only for source-name queries.
- Global completion/dependency order, SCC behavior, acceptance/rejection, CTFE,
  and diagnostics are unchanged.
- Module views retain IDs/locators and necessary language-visible spellings,
  not copied owner identities.
- Typed-AST, semantic occurrence, LSP, Core, and replay output are exact.
- Generated C shows unboxed IDs and no per-ID table retention.
- Focused global-heavy work reduces allocations or retired instructions with
  no material latency or RSS regression.
- Focused, changed, Stage 06, compiler, leak, and sanitizer gates pass.

## Stop Conditions

Stop and consult before:

- changing global completion or CTFE semantics;
- changing the raw definition frontier or Core IDs;
- retaining structural and scalar global IDs together;
- adding a table pointer to every ID/binding;
- using `None`, an empty path, or a magic integer to represent a non-graph
  global category;
- adding a cache or invalidation; or
- broadening into field, trait, implementation, body, or semantic-type work.

## Implementation Result

`GlobalId` now wraps the reserved `GlobalDefinition` ID, and descriptive facts
are projected through the graph `DefinitionTable`. Accepted bindings no longer
duplicate the raw definition integer. Exact lookups and module-view locators
are definition-ID-addressed, while source-name indexes remain only at source
lookup boundaries. Cross-product operations fail closed on definition-table
provenance, including completed-table replacement with a different slot order.

The accepted-stage profile retained identical outputs and checksums while
reducing allocations from 7,344,621 to 7,339,481, allocated bytes from
17,344,984 to 17,336,792, and retained objects from 222,319 to 222,255. Paired
wall-clock samples crossed in both directions, with no repeatable latency
regression. Production changed by +572/-342 lines, focused tests by +212/-21,
and the benchmark fixture by +9/-2.
