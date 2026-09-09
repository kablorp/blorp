# Issue 70: Make Nominal Type IDs Definition-Backed

**Status:** Implemented

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Prerequisites:** Issue 61B publishes one canonical graph `DefinitionTable`
whose type-definition rows preserve the current module, name, and span facts;
Issue 68 establishes the scalar constructor precedent; and Issue 69 establishes
category-checked row projection plus exact table-allocation provenance.

**Can proceed independently of:** Issue 71. Integrate the two sequentially
because both touch Stage 06 declaration products.

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

Issue 61B makes those strings redundant for internal identity and owner joins,
and Issue 69 proves the intended representation and provenance pattern.
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
- Issue 69's final callable identity, exact-provenance, and generated-C result;
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
cross-product admission boundary, require
`definition_tables_share_provenance`; compatible module tables, equal rows, or
equal allocation frontiers are not sufficient because unrelated definition
tables may issue the same integer. Do not attach a provenance pointer/token to
each ID.

## Authority Storage Cutover

### Exact type-header lookup

Scalarizing `TypeId` is not enough if `TypeHeaderTable` continues to recover a
name, fetch every same-name header, and scan those candidates for identity.
Publish an exact integer index when the immutable header table is built:

```blorp
private record TypeHeaderTable {
	headers: List[TypeHeader],
	header_index_by_definition_id: Dict[Int, Int],
	header_indices_by_name: Dict[String, List[Int]],
	header_indices_by_module: List[ModuleTypeHeaderIndices],
	owner_scope: PreparedModuleScope
}
```

Name and module indexes remain necessary for unresolved source lookup and
visibility. Exact `TypeId` lookup must use only the definition integer and
visit at most one candidate. Prefer a direct dense locator only if the existing
definition-table range makes it compact; do not allocate a sparse list sized
by an unrelated bootstrap frontier.

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

Prefer a direct dense row locator only if the Issue 61B table layout makes it
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
path for entries without a graph-issued ID. Remove those sentinel columns, but
do not wrap every scalar graph `TypeId` in a newly managed data-carrying union.
One viable representation keeps a single payload list and publishes separate
relationship indexes:

```blorp
private record AcceptedUnionTableRep {
	unions: List[AcceptedUnionEntry],
	graph_union_indices_by_definition_id: Dict[Int, Int],
	builtin_union_indices_by_name: Dict[String, Int]
}
```

This also represents the existing case where a compiler builtin name matches
accepted graph metadata: both indexes may deliberately point at the same
payload row. A tagged identity union is acceptable only if generated C proves
that it does not allocate or add ARC traffic to every graph union. Do not mint
a fake `DefinitionId`, use `None` as a long-term category tag, or use `""` as
an owner sentinel.

## Construction Boundary

Type skeleton construction currently creates `TypeId` from module, name, and
span. It should instead claim the already reserved definition row through a
category-specific index query:

```blorp
definition_id ?= definition_index_find_type_definition(
	index,
	module_table,
	module_id,
	name,
	span,
)
type_id ?= type_id_from_definition_table(definitions, definition_id)
```

Failure is an internal phase-product error because definition reservation and
skeleton construction disagree. Do not silently construct a structural
fallback identity. The named type-definition query must reject callable,
constructor, global, field, trait, and implementation rows even when their
integer exists.

Accepted alias/record/union tables should receive the same definition table as
their skeleton graph. Validate exact allocation provenance once during opaque
product construction, then use integer IDs internally.

## Scope

In scope:

- scalar, definition-backed graph `TypeId`;
- checked `DefinitionId -> TypeId` construction;
- table-based type owner/name/span accessors;
- all production `TypeId` constructor, equality, and accessor call sites;
- an exact integer `TypeId -> TypeHeader` index alongside the existing
  unresolved-name and module visibility indexes;
- alias, record, union, type-header, and module-view identity indexes;
- deletion of `type_id_storage_key`;
- removal of redundant graph-owned type owner-path columns;
- explicit graph/builtin union index domains without sentinel identity rows;
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

Build one reusable Stage 06 definition-table fixture for these tests instead
of teaching each suite to reserve the same graph rows independently. Report
fixture/support lines separately from behavior-test lines so table setup does
not hide implementation growth.

### 2. Change the ID representation at the skeleton boundary

Make the union/record/alias/builtin-type skeleton claim its definition-backed
ID. Convert header graph APIs until the compiler typechecks. Do not temporarily
add `definition_id` to `TypeIdRep`.

### 3. Replace identity-only operations

Convert equality, dictionaries, seen sets, dependency sets, and exact lookup
to integer IDs first. Add the exact type-header index in this step. These
readers should not query the definition table or recover a source name before
performing an exact lookup.

Run the early performance gate after this step. Do not begin the authority and
owner-path cleanup unless scalar construction plus exact integer lookup shows
fewer focused allocations and retired instructions without a Phase 01-06
regression.

### 4. Replace descriptive accessors

Pass or retain the table at the smallest coherent owner. Convert owner/name/span
readers and keep path materialization at diagnostics/projection boundaries.
When one loop needs multiple descriptive fields, validate and load the
definition row once and reuse it; do not perform separate table probes for
name, owner, and span.

### 5. Cut over accepted type authorities

Migrate alias, record, and union tables and module views one family at a time.
After each family passes, delete its string storage-key index and owner-path
column before moving to the next.

### 6. Make builtin identity explicit

Replace `Option[TypeId]`/empty-path category signaling with separate graph and
builtin relationship indexes. Preserve shared payload rows when accepted graph
metadata exactly matches a compiler builtin. Update constructor lookup tests
and inspect generated C for accidental re-boxing.

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

Use two explicit measurement points:

1. **Early stop gate after scalar identity and exact type-header lookup.** Build
   clean parent and candidate compilers, run the type-heavy focused fixtures,
   and run an immutable Phase 01-06 self-check. If allocations and retired
   instructions do not improve in the focused owner—or if Phase 01-06
   instructions, latency, or RSS regress repeatably—stop before migrating the
   three accepted authority families.
2. **Final gate after authority and builtin cutover.** Rebuild both snapshots
   and repeat the same workloads in balanced order. Do not reuse counters from
   an earlier production snapshot.

Keep the entire imported source graph immutable for parent/candidate
comparison, not only the root `main.brp`; another worktree's dirty imports can
shift absolute instruction counts. Ensure no concurrent compiler or benchmark
process is consuming CPU while collecting exact counters.

## Performance Acceptance

This issue is expected to produce a measurable focused win because it removes
managed identity and serialized keys from high-volume Stage 06 paths. Require:

- exactly zero storage-key string constructions for already resolved `TypeId`
  lookup;
- fewer allocations/releases in type-heavy focused workloads;
- fewer retired instructions in the early skeleton/type-header checkpoint;
- fewer final Phase 01-06 retired instructions on an immutable self-check; and
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
- Exact type-header lookup uses an integer index and visits at most one
  candidate; name indexes remain only for unresolved source lookup.
- Descriptive owner/name/span facts come from the issuing definition/module
  tables at named boundaries, with one row read reused when several fields are
  needed together.
- `type_id_storage_key` and all resolved-ID serialized compound keys are
  deleted.
- Accepted alias, record, and union authorities use integer ID indexes or a
  justified direct row layout.
- Redundant graph-owned type owner-path columns are deleted.
- Graph and builtin union relationships are indexed explicitly; no `None`,
  empty path, magic ID, or newly managed per-entry identity wrapper acts as a
  category sentinel.
- Module visibility, alias redirection, record lookup/inference, union
  constructor lookup, containment, and ambiguity order are unchanged.
- Diagnostic text, typed-AST/semantic output, replay output, and definition
  frontier are exact.
- Definition/module tables are retained once per coherent product, never per
  `TypeId` or type row.
- Focused allocator/instruction measurements and final Phase 01-06 retired
  instructions improve, with no material latency or peak-memory regression.
- Changed, Stage 06, compiler, leak, and sanitizer gates pass.

## Implementation Result

`TypeId` is now an opaque `DefinitionId`, and its only constructor validates
that the requested definition row has `TypeDefinitionKind`. Identity-only
comparison and exact lookup use the scalar definition integer. The old managed
`TypeIdRep`, structural constructor, and `type_id_storage_key` serialization
path are deleted.

Declaration skeleton construction claims the type rows already reserved by
the graph definition index. `TypeHeaderTable` publishes one exact
`Dict[Int, Int]` locator in addition to the unresolved-name and module indexes.
The header retains owner ID and source name once as a measured hot projection;
this avoids repeatedly loading the same definition row during header and
accepted-view publication without restoring a second nominal identity.

Accepted alias, record, and union authorities use integer identity indexes.
Per-entry owner-path columns are removed; module authorities retain at most one
owner path for localization. Canonical names are validated against one loaded
definition row at the opaque construction boundary. Production accepted-graph
builders validate exact `DefinitionTable` allocation provenance before
combining header and bound-module products. Builtin and graph union lookup use
separate indexes, and a matching builtin may explicitly share a graph payload
row without a `None`, empty-path, or fabricated-ID sentinel.

Generated-C inspection confirms that nominal IDs and type-skeleton IDs are
passed as `long`; there is no generated `TypeIdRep`, storage-key helper, or
ARC-managed per-ID provenance carrier. Parent and candidate compilers both
checked the immutable parent source graph through Phase 06. Five balanced
alternating runs produced byte-identical output with SHA-256
`c1758b804e292be62860bce968c8cee14b4b6a8fec681ff19c5318e5195c0963`:

| Metric | Parent median | Candidate median | Difference |
| --- | ---: | ---: | ---: |
| retired instructions | 161,533,126,450 | 161,086,636,297 | -0.2764% |
| wall seconds | 17.78 | 17.51 | -1.5186% |
| peak RSS bytes | 835,600,384 | 834,125,824 | -0.1765% |

Host contention made elapsed cycles noisy, so retired instructions remain the
primary acceptance signal. They improved in every paired candidate run, while
wall time and peak RSS show no regression.

Validation passed 964/964 Stage 06 focused tests, 29/29 structural declaration
boundary checks, 4,314/4,314 compiler tests, 3,620/3,620 compiler sanitizer
tests, and 888/888 final leak checks. One earlier Stage wrapper invocation had
a single 60-second leak-batch timeout while several worktrees saturated the
host; the explicit rebuilt-candidate leak gate subsequently passed completely.
Final code review reported no findings.

The implementation diff before recording this result was +942/-551 production
lines, +102/-37 benchmark lines, and +629/-234 test/support lines. Most net
test growth is the reusable definition-backed fixture and category,
provenance, canonical-name, and builtin-domain regressions; production growth
comes from threading the one shared table to descriptive boundaries rather
than retaining managed descriptive state per ID.

## Stop Conditions

Stop and consult before:

- interning `SemanticType` or unresolved metas;
- changing type visibility, alias, containment, or constructor semantics;
- adding a managed graph/table carrier to every `TypeId`;
- keeping structural and scalar type identities in parallel;
- using a fabricated definition/module ID for builtins;
- retaining owner-path caches without a measured named consumer;
- changing external protocol schemas; or
- broadening into non-type declaration normalization from Issues 71-73;
- accepting compatible-but-separately-allocated definition tables as one ID
  domain;
- introducing a managed identity union around every graph `TypeId`; or
- continuing past the early scalar/index checkpoint without a measured
  focused improvement and a clean Phase 01-06 regression check.
