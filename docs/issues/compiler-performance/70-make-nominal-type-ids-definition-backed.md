# Issue 70: Make Nominal Type IDs Definition-Backed

**Status:** Ready after Issue 68

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependency:** Issue 61B must publish one canonical graph `DefinitionTable`
whose type-definition rows preserve the current module, name, and span facts.

**Can proceed independently of:** Issue 69 after Issue 68, subject to
integration overlap in typed projections.

**Blocks:** Issues 72-73 and later accepted semantic type normalization.

## Objective

Replace the managed nominal type identity:

```blorp
private record TypeIdRep {
	module_id: ModuleId,
	name: String,
	span: SourceSpan
}
```

with a category-safe, unboxed ID backed by the canonical definition table.
Then cut the accepted alias, record, and union authority families over to that
ID in the same issue, deleting serialized type identity keys and duplicate
owner-path columns.

The completed relationship is:

```text
TypeId -> DefinitionId -> DefinitionRow {
  module_id,
  kind = TypeDefinition,
  name,
  span
}
```

The table is retained once by a containing graph/authority product. `TypeId`
itself contains only an integer. There must not be a migration state in which
each type carries both the old structural identity and a new definition ID.

## Why This Has Concrete Upside

The current `TypeId` already benefited from Issue 47's unboxed `ModuleId`, but
it remains a managed record because name and `SourceSpan` are managed. It is
copied and compared throughout declaration skeletons, type headers,
containment, aliases, records, unions, module views, inference, and semantic
projection.

Hot authorities cannot use the record directly as an integer dictionary key,
so they serialize part of it:

```blorp
pure func type_id_storage_key(id: TypeId) -> String:
	module_id_table_index(type_id_module_id(id)).to_string()
		+ "\n"
		+ type_id_name(id)
```

The accepted alias, record, and union tables then retain indexes such as:

```text
Dict[String, Int] type_identity_indices_by_key
Dict[String, Int] record_indices_by_type_key
Dict[String, Int] union_indices_by_type_key
```

and parallel descriptive columns such as:

```text
transparent_owner_module_paths
opaque_owner_module_paths
owner_module_paths
canonical_constructors_by_module_path
```

Issue 68 makes those strings redundant for internal identity and owner joins.
The expected benefit is therefore broader than changing an equality function:

- smaller copied IDs;
- integer equality;
- integer dictionary keys or direct row indexes;
- no `to_string + concatenate` storage-key construction;
- fewer retained name/span/path references; and
- owner lookup through one table row instead of parallel columns.

Historical Stage 06 measurements matter here. Replacing a type's owner with an
unboxed module ID reduced declaration-skeleton allocations by millions and
improved that checkpoint, while retaining a managed scope/table carrier per
type materially regressed latency. This issue must preserve the successful
shape: unboxed ID per entity, shared table once.

## Required Reading And Audit

Before editing, read and inventory:

- Issue 61B's final table layout and category-validation APIs;
- `graph/type_identity.brp` and every importer;
- `headers/declaration_skeleton.brp`;
- accepted alias, record, and union graph/header/authority files;
- `headers/type_header_graph.brp` and type containment/dependency code;
- `decl.brp`, `infer.brp`, `types.brp`, and semantic occurrence projection;
- module type visibility/import views;
- typed-AST JSON and LSP type identity materialization;
- builtin union/type construction; and
- Stage 06 type-header, alias, record, union, graph provenance, replay, leak,
  sanitizer, and generated-C tests.

Use `rg` to classify every call to:

- `type_id`;
- `type_id_name`;
- `type_id_module_id`;
- `type_id_source_span`;
- `type_ids_equal`; and
- `type_id_storage_key`.

For every reader, record whether it needs:

1. identity only;
2. owner module for a join;
3. source name for a name index;
4. span for diagnostics;
5. canonical module path for diagnostics/projection; or
6. a graphless/builtin identity that has no ordinary source row.

This prevents table lookups from being added where an integer comparison is
enough and prevents diagnostic facts from being discarded.

## Target ID Contract

`TypeId` should be constructible only from a `TypeDefinition` row:

```blorp
opaque type TypeId = DefinitionId

pure func definition_table_type_id(
	table: DefinitionTable,
	definition_id: DefinitionId,
) -> Option[TypeId]

pure func type_id_definition_id(id: TypeId) -> DefinitionId

pure func type_ids_equal(left: TypeId, right: TypeId) -> Bool:
	definition_ids_equal(
		type_id_definition_id(left),
		type_id_definition_id(right),
	)
```

The existing descriptive accessors become table queries:

```blorp
pure func definition_table_type_name(
	table: DefinitionTable,
	id: TypeId,
) -> Option[String]

pure func definition_table_type_module_id(
	table: DefinitionTable,
	id: TypeId,
) -> Option[ModuleId]

pure func definition_table_type_span(
	table: DefinitionTable,
	id: TypeId,
) -> Option[SourceSpan]
```

Do not expose an unchecked `type_id(DefinitionId)` constructor. Category
validation belongs at skeleton/table construction, not at every downstream
read.

Within a coherent opaque product, integer equality is sufficient. At a rare
cross-product admission boundary, validate definition-table compatibility
before accepting IDs. Do not attach a provenance pointer/token to each ID.

## Authority Storage Cutover

### Integer identity indexes

Replace serialized string keys with the unboxed definition integer:

```blorp
private record AcceptedRecordTableRep {
	definition_table: DefinitionTable,
	known_type_indices_by_id: Dict[Int, Int],
	records: List[AcceptedRecordEntry],
	record_indices_by_id: Dict[Int, Int]
}
```

Names remain valid external lookup keys when the query starts from source
spelling. The forbidden operation is serializing an already resolved `TypeId`
back into a compound string key.

Prefer a direct dense row locator only if the Issue 68 table layout makes it
simple and measurement shows it avoids dictionaries without large sparse
lists. Otherwise `Dict[Int, Int]` is a valid incremental result.

### Remove owner-path columns

For graph-owned entries, derive the owner path only when a diagnostic,
semantic projection, import spelling, or external API needs it:

```blorp
owner_id ?= definition_table_type_module_id(table.definitions, entry.id)
owner_path ?= module_table_canonical_path(
	definition_table_module_table(table.definitions),
	owner_id,
)
```

Do not replace every removed path with a cached path column under another
name. If a hot production consumer truly needs the path repeatedly, measure it
and keep one explicitly named projection at that boundary, not in every type
row.

### Module views

Module views should retain ordered `TypeId` or compact locator values plus
language-visible source names. They must not copy a complete type identity to
prove ownership.

Visibility and ambiguity behavior remains exact. In particular:

- local definitions retain precedence where currently specified;
- selective, qualified, and prelude imports preserve order;
- same-name types in different modules remain distinct; and
- aliases preserve canonical redirect semantics.

### Builtin unions and types

`AcceptedUnionTableRep` currently uses `List[Option[TypeId]]` and an empty owner
path for entries without a graph-issued ID. Replace that implicit distinction
with an explicit variant, for example:

```blorp
union AcceptedUnionIdentity:
	GraphUnionIdentity(TypeId)
	CompilerBuiltinUnionIdentity(BuiltinUnionId)
```

The exact builtin ID type should match current builtin authority. Do not mint
a fake `DefinitionId`, use `None` as a long-term category tag, or use `""` as
an owner sentinel.

## Construction Boundary

Type skeleton construction currently creates `TypeId` from module, name, and
span. After Issue 68, it should claim the already reserved definition row:

```blorp
definition_id ?= definition_index_find_source_definition(
	index,
	module_id,
	TypeDefinition,
	name,
	None,
	span,
)
type_id ?= definition_table_type_id(definitions, definition_id)
```

Failure is an internal phase-product error because definition reservation and
skeleton construction disagree. Do not silently construct a structural
fallback identity.

Accepted alias/record/union tables should receive the same definition table as
their skeleton graph. Validate compatibility once during opaque product
construction, then use integer IDs internally.

## Scope

In scope:

- scalar, definition-backed graph `TypeId`;
- checked `DefinitionId -> TypeId` construction;
- table-based type owner/name/span accessors;
- all production `TypeId` constructor, equality, and accessor call sites;
- alias, record, union, type-header, and module-view identity indexes;
- deletion of `type_id_storage_key`;
- removal of redundant graph-owned type owner-path columns;
- explicit builtin union/type identity variants; and
- exact external/diagnostic materialization at boundaries.

Out of scope:

- structural interning of `SemanticType`;
- flattening parsed or typed type expressions;
- changing alias opacity, record inference, union constructor, containment, or
  visibility semantics;
- normalizing callable/global/trait/impl IDs not required by type authority;
- changing external semantic/LSP identity schemas;
- adding path caches or invalidation; and
- normalizing `SourceSpan` itself.

## Implementation Sequence

### 1. Add structural and behavior tests first

Add failing tests proving:

- one reserved type definition yields one scalar `TypeId`;
- a non-type definition cannot become a `TypeId`;
- same name/span in different modules remains distinct;
- independent table domains are rejected;
- aliases, records, and unions resolve by exact ID without storage-key strings;
- external owner path/name/span projection remains exact; and
- builtin union identity is explicit.

### 2. Change the ID representation at the skeleton boundary

Make the union/record/alias/builtin-type skeleton claim its definition-backed
ID. Convert header graph APIs until the compiler typechecks. Do not temporarily
add `definition_id` to `TypeIdRep`.

### 3. Replace identity-only operations

Convert equality, dictionaries, seen sets, dependency sets, and exact lookup
to integer IDs first. These readers should not query the definition table.

### 4. Replace descriptive accessors

Pass or retain the table at the smallest coherent owner. Convert owner/name/span
readers and keep path materialization at diagnostics/projection boundaries.

### 5. Cut over accepted type authorities

Migrate alias, record, and union tables and module views one family at a time.
After each family passes, delete its string storage-key index and owner-path
column before moving to the next.

### 6. Make builtin identity explicit

Replace `Option[TypeId]`/empty-path category signaling with an exhaustive
variant and update constructor lookup tests.

### 7. Delete old identity code and reprofile

Delete `TypeIdRep`, unchecked structural constructors, storage-key helpers,
parallel owner paths, and adapters used only by old tests. Report source and
test diffstats separately.

## TDD And Fast Feedback Loop

Use the compiler test ownership manifest to run the exact owner for each slice.
At minimum, iterate with:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_type_header_dependencies.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_alias_authority.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_record_authority.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_union_authority.brp
scripts/compiler-check --changed
```

If an exact filename differs on current main, use
`blorp/test/compiler/compiler_test_ownership.json` rather than adding a
duplicate suite.

After all three authority families pass:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Inspect generated C after the skeleton cut and after the authority cut. Verify:

- `TypeId` fields are unboxed integers;
- ID equality has no string/span comparison or retain/release work;
- resolved-ID indexes use integer keys;
- there is no call to `type_id_storage_key`;
- definition/module tables are retained by products, not per type row; and
- removed owner paths do not reappear in renamed parallel columns.

## Performance Harness

Use and narrowly extend existing fixtures rather than inventing a second
compiler model:

- `compiler_definition_index_profile` for type-definition row claims;
- `compiler_typecheck_phase_profile` for skeleton, type-header, alias, record,
  union, and accepted graph checkpoints;
- `compiler_alias_resolution_profile` for alias lookup;
- the type-header mixed profile for same-name and containment-heavy types; and
- production `compiler_typecheck_replay` for exact output and allocator/RSS
  evidence.

The focused workload should independently vary:

- module count;
- type count per module;
- same-name types across modules;
- alias/record/union proportions;
- visible/imported type lookup count;
- exact resolved-ID lookup count; and
- union constructor count, including builtins.

Add benchmark-only counters for:

- `TypeId` values constructed/copied;
- storage-key strings constructed;
- string versus integer index probes;
- candidate comparisons;
- definition-row descriptive reads;
- owner paths materialized; and
- table publications.

All logical checksums, lookup results, diagnostics, ID order, and definition
frontier must match.

## Performance Acceptance

This issue is expected to produce a measurable focused win because it removes
managed identity and serialized keys from high-volume Stage 06 paths. Require:

- exactly zero storage-key string constructions for already resolved `TypeId`
  lookup;
- fewer allocations/releases in type-heavy focused workloads;
- fewer retired instructions in at least the skeleton/type-header or accepted
  authority checkpoint; and
- no repeatable Phase 01-06 latency or peak-RSS regression.

Do not accept a managed table pointer on each `TypeId` to improve ergonomics.
Historical evidence already shows that shape can reduce allocations while
materially degrading latency.

## Acceptance Criteria

- `TypeId` is a category-validated scalar backed by a `TypeDefinition` row.
- Generated C represents `TypeId` as an unboxed integer.
- No graph type row repeats module ID, source name, or span inside `TypeId`.
- Identity-only equality and membership use integer operations without table
  reads.
- Descriptive owner/name/span facts come from the issuing definition/module
  tables at named boundaries.
- `type_id_storage_key` and all resolved-ID serialized compound keys are
  deleted.
- Accepted alias, record, and union authorities use integer ID indexes or a
  justified direct row layout.
- Redundant graph-owned type owner-path columns are deleted.
- Builtin type/union identity is explicit; no `None`, empty path, or magic ID
  acts as a category sentinel.
- Module visibility, alias redirection, record lookup/inference, union
  constructor lookup, containment, and ambiguity order are unchanged.
- Diagnostic text, typed-AST/semantic output, replay output, and definition
  frontier are exact.
- Definition/module tables are retained once per coherent product, never per
  `TypeId` or type row.
- Focused allocator and instruction measurements improve, with no material
  latency or peak-memory regression.
- Changed, Stage 06, compiler, leak, and sanitizer gates pass.

## Stop Conditions

Stop and consult before:

- interning `SemanticType` or unresolved metas;
- changing type visibility, alias, containment, or constructor semantics;
- adding a managed graph/table carrier to every `TypeId`;
- keeping structural and scalar type identities in parallel;
- using a fabricated definition/module ID for builtins;
- retaining owner-path caches without a measured named consumer;
- changing external protocol schemas; or
- broadening into non-type declaration normalization from Issues 71-73.
