# Issue 72: Make Field IDs Definition-Backed

**Status:** Implemented

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:**

- Issue 61B publishes canonical `FieldDefinition` rows.
- Issue 70 makes the parent nominal `TypeId` definition-backed.

**Blocks:** The final relation and module-view checkpoint in Issue 73.

## Objective

Introduce a category-checked `FieldId` for graph-owned record fields and use it
through type headers, accepted record authority, inference, typed expressions,
updates/patterns, semantic occurrences, and external projection. Publish the
field-to-parent-type relation once and remove untyped `Option[Int]` field
identity from accepted/resolved paths.

The implemented relationship is:

```text
FieldId -> DefinitionId -> DefinitionRow {
  module_id,
  kind = FieldDefinition,
  name,
  owner_name,
  span
}

FieldId -> parent TypeId
```

The definition row owns source identity. The accepted record/type authority
owns the exact parent relation. `FieldId` itself is one unboxed integer.

## Current Production Shape

`DefinitionIndex` reserves one `FieldDefinition` for every parsed record field.
Later code does not expose a category-safe field ID. Instead, several records
carry `Option[Int]`, including:

```blorp
record FieldDecl {
	name: String,
	field_type: SemanticType,
	definition_id: Option[Int]
}

record TypedRecordField {
	name: ParsedIdentifier,
	value: TypedExpr,
	span: SourceSpan,
	definition_id: Option[Int]
}

record TypedRecordFieldInfo {
	name: String,
	source_type: SemanticType,
	semantic_type: SemanticType,
	definition_id: Option[Int],
	declaration_span: SourceSpan,
	selection_span: SourceSpan
}
```

`TypedExprInfo.resolved_definition_id` and several assignment/pattern helpers
also use raw optional integers for different declaration categories. This
makes it easy to pass a callable/global/type integer where a field definition
is expected and forces semantic occurrence code to recover category and owner
from surrounding shape.

The current `None` cases need an explicit audit. Some may mean an unresolved or
synthetic field; some may only reflect that old APIs did not require the
definition index. They must not all be assigned one guessed meaning.

## Required Reading And Audit

Read before editing:

- Issues 68 and 70 implementation results;
- field reservation in `graph/definition_index.brp`;
- record skeleton and field construction in
  `headers/declaration_skeleton.brp` and `headers/type_header_graph.brp`;
- accepted record graph and authority files;
- `type_system/env.brp` field declarations;
- every `definition_id` field/read in `decl.brp` and `infer.brp`;
- constructor/record patterns, record construction, update, assignment, UFCS
  field resolution, and callable-field lookup;
- `graph/semantic_occurrence.brp`, `type_occurrence.brp`, typed-AST JSON, and
  LSP conversion; and
- record field, pattern, update, recovery, replay, leak, sanitizer, and profile
  tests.

Build a `None`-state ledger before changing types:

| Current location | `Some(Int)` means | `None` means | Accepted or recovery? | Target |
| --- | --- | --- | --- | --- |
| `FieldDecl.definition_id` | accepted graph field | audit | audit | `FieldIdentity` |
| `TypedRecordField.definition_id` | resolved field occurrence | audit | audit | `Option[FieldId]` or explicit union |
| `TypedExprInfo.resolved_definition_id` | mixed declaration target | audit | audit | typed `ResolvedDefinition` |

The implementation result must include the completed ledger. Do not use field
names or surrounding expression syntax to distinguish states that can be
represented explicitly.

## Target ID And Parent Relation

Make the ID a checked scalar:

```blorp
opaque type FieldId = Int

pure func definition_table_field_id(
	table: DefinitionTable,
	runtime_definition_id: Int,
) -> Option[FieldId]

pure func field_id_definition_id(id: FieldId) -> Int
```

`FieldId` uses the same non-negative runtime value as its checked
`DefinitionId`; construction remains private to category-checking table APIs.
Typed nodes store a scalar `ResolvedFieldIdentity` rather than
`Option[FieldId]`. This is the explicit graph-field-or-no-graph-field state,
and avoids an existing lowering limitation that otherwise boxes the option in
every containing record and union variant.

## Completed Absence-State Ledger

| Location | Present state | Absent state | Result |
| --- | --- | --- | --- |
| `TypeHeaderField.id` | reserved, category-checked field row | impossible in an accepted header | mandatory `FieldId` |
| `AcceptedFieldRow.id` | accepted field with exact parent and source index | impossible | mandatory `FieldId` |
| provisional `FieldDecl` | no graph identity is published yet | normal before accepted publication | identity removed from `FieldDecl` |
| `TypedRecordFieldInfo.field_id` | accepted declaration field | only recovery/unindexed construction | scalar `ResolvedFieldIdentity` |
| `TypedRecordField.field_id` | resolved record literal/update field | unknown/recovery or CTFE-synthetic field | scalar `ResolvedFieldIdentity` |
| `TypedFieldAccessExpr` identity | resolved record field access, including callable-field/UFCS resolution | tuple field, qualified module member, or recovery | scalar `ResolvedFieldIdentity` |
| `ResolvedRecordField.field_id` | accepted ordered record shape | provisional/recovery shape | scalar `ResolvedFieldIdentity` |
| `TypedExprInfo.resolved_definition_id` | existing non-field mixed identities | expression is not such a reference | unchanged; field access projects its `FieldId` first |

The audit found no record-field assignment target or record-field pattern in
the current parsed or typed language. Those prospective paths were therefore
removed from the implementation scope rather than represented heuristically.
Tuple fields, qualified module members, recovery expressions, and CTFE-created
record values legitimately carry the explicit missing state; none receives a
fabricated graph ID.

Publish exact parent ownership in the accepted type/record product:

```blorp
record AcceptedFieldRow {
	id: FieldId,
	parent: TypeId,
	field_type: SemanticType,
	index: Int
}
```

or equivalent aligned columns. The parent is a relationship, not part of
`FieldId`. `index` is the source/layout slot only if current record semantics
already define and consume it.

Construction validates:

- the definition row kind is `FieldDefinition`;
- the field and parent type have compatible issuing tables;
- the definition row's module matches the parent type owner;
- source name/span/owner name agree with the parsed declaration; and
- field order is exact.

After publication, lookup by resolved `FieldId` uses integer addressing.
Lookup that begins with a source field name may continue using a name index,
but its value should be an ordered `FieldId`/row locator.

## Represent Absence Explicitly

If the audit finds multiple legitimate non-`FieldId` states, use a precise
union at the relevant boundary:

```blorp
union ResolvedFieldIdentity:
	GraphFieldIdentity(FieldId)
	TupleFieldIdentity(Int)
	RecoveryFieldIdentity
```

This example is illustrative. Include only states that production actually
has. A tuple position is not a graph field definition, and recovery is not an
accepted field. Do not fabricate IDs for them.

For places where absence simply means “this expression is not a definition
reference,” prefer a category-aware union over a broadly typed
`Option[DefinitionId]` if the field already mixes globals, fields, callables,
and types:

```blorp
union ResolvedDefinition:
	ResolvedFieldDefinition(FieldId)
	ResolvedGlobalDefinition(GlobalId)
	ResolvedCallableDefinition(CallableId)
	ResolvedTypeDefinition(TypeId)
```

Only introduce this shared union if it replaces the existing mixed raw field
in production; do not broaden Issue 72 into every occurrence family.

## Typed And Semantic Projection

Record construction/update/pattern nodes should retain `FieldId` only when
resolution succeeded. Semantic occurrence rows can then project the exact
definition integer and source facts without rescanning the record type or
matching by field name.

Typed-AST JSON and LSP output must remain byte-identical unless a separate
schema change is approved. Serialize the raw numeric definition value at the
output boundary:

```blorp
json_int(definition_id_runtime_value(field_id_definition_id(field_id)))
```

Materialize declaration spans and module paths from definition/module tables
only when the protocol requires them. Do not retain those strings on every
typed field occurrence.

## Scope

In scope:

- scalar, category-checked `FieldId`;
- exact field-to-parent-`TypeId` rows or aligned relation columns;
- accepted record field metadata and lookup;
- field identities in `Env` only where accepted/provisional field metadata is
  intentionally present;
- record construction, update, access, and UFCS field resolution;
- semantic occurrences and typed-AST/LSP projection;
- explicit tuple/synthetic/recovery field states found by the audit; and
- deletion of raw optional field definition identity and redundant owner/name
  matching.

Out of scope:

- changing record layout, inference, update, pattern, or UFCS semantics;
- changing tuple indexing semantics;
- scalarizing globals, traits, or implementations;
- normalizing all mixed `resolved_definition_id` uses not involving fields;
- changing external schemas;
- interning semantic types or spans;
- adding caches/invalidation; and
- changing Core/backend field layout.

## Implementation Sequence

### 1. Complete the absence-state ledger and failing tests

Add tests for an accepted graph field, same-name fields on different records,
same-name records across modules, tuple fields, recovery/unresolved fields, and
an incompatible definition table. At least one test must require typed
`FieldId` behavior unavailable in the old raw integer API.

### 2. Claim field IDs during type-header construction

Resolve the reserved `FieldDefinition` row, validate category/owner, and build
the accepted parent relation. Fail the phase product on internal mismatch; do
not leave an accepted field with `None`.

### 3. Cut over accepted record authority and environments

Use IDs/locators in field tables and name indexes. Remove duplicate definition
integers and owner-name matching where exact IDs are already known. Keep
provisional environment states explicit and transient.

### 4. Cut over inference and typed nodes

Update field access, calls, construction, update, assignment, and patterns.
Use exhaustive unions to force every tuple/recovery case to be handled.

### 5. Cut over occurrences and external projection

Emit exact numeric IDs and source facts from the issuing tables. Preserve JSON,
LSP, and diagnostic ordering/content.

### 6. Delete residue and measure

Remove obsolete raw-ID helpers, name/owner re-resolution, and impossible test
constructors. Report production and test diffstats separately.

## TDD And Fast Feedback Loop

Use current manifest owners. A practical loop is:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_type_header_dependencies.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_record_authority.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_typed_ast_json.brp
scripts/compiler-check --changed
```

Then:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Inspect generated C and confirm:

- `FieldId` is an unboxed integer;
- accepted/resolved field payloads do not carry both `FieldId` and raw
  definition integer;
- the parent relation is stored once per field declaration, not per occurrence;
- resolved field equality/lookup uses integers; and
- table pointers are retained by authority products, not field IDs/occurrences.

## Performance Harness

Narrowly extend the type-header/accepted-record/inference profile fixtures.
Vary:

- modules and records per module;
- fields per record;
- same-name fields across different parent records;
- field access, construction, and update occurrence count;
- resolved versus recovery occurrences; and
- source-name versus exact-ID query count.

Record exact field rows, parent edges, raw/storage-key constructions, name and
integer probes, parent/name comparisons, semantic occurrences, allocations,
releases, retained bytes, retired instructions, and semantic checksums.

The expected win scales with resolved field occurrences and accepted field
metadata copies. Require fewer allocations or retired instructions in at least
one field-heavy production-shaped workload and no material latency or peak-RSS
regression.

## Acceptance Criteria

- Every accepted graph field has one category-checked, unboxed `FieldId` backed
  by its existing `FieldDefinition` row.
- The field-to-parent-`TypeId` relation is exact, ordered, validated, and stored
  once per declaration.
- Accepted graph field rows never use `None` for identity.
- Tuple, synthetic, unresolved, and recovery field states are explicit and do
  not use fabricated graph IDs.
- Resolved field occurrences carry `FieldId`, not raw `Int`.
- Exact lookup/equality uses integers; source-name indexes remain only for
  source-name queries.
- Record construction, access, update, assignment, pattern, inference, UFCS,
  visibility, ambiguity, and diagnostics are unchanged.
- Typed-AST JSON, semantic occurrences, LSP output, replay output, and
  definition frontier remain exact.
- Generated C shows unboxed IDs and no per-occurrence table retention.
- Focused field-heavy work reduces allocations or retired instructions with no
  material latency or RSS regression.
- Focused, changed, Stage 06, compiler, leak, and sanitizer gates pass.

## Implementation Result

`FieldId` is now a category-checked opaque integer backed by an existing
`FieldDefinition` row. Accepted type headers and record authority require it,
and `AcceptedFieldRow` stores its exact parent `TypeId`, semantic type, and
source-order index once per declaration. Accepted construction rejects a wrong
parent, wrong order, duplicate identity, wrong module/owner, or wrong
definition category.

Typed record fields, record shapes, and field accesses carry a scalar
`ResolvedFieldIdentity`. The scalar uses a named impossible negative value for
the legitimate tuple/module/recovery/synthetic cases in the completed ledger;
this avoids the per-occurrence box that `Option[FieldId]` generated inside
records and union variants. Record-field assignment and record-field patterns
do not exist in the current parsed or typed language and were not fabricated
for this issue.

Source field spelling is resolved once through the existing visible record
shape. The resulting `FieldId` addresses a compact exact locator in accepted
record authority, validates the parent `TypeId`, and substitutes only the
selected field type. The previous path localized and substituted the complete
record field list before selecting one field. Semantic occurrences,
typed-AST JSON, CTFE, Core lowering, and lint project the raw integer only at
their existing boundaries; external schemas did not change.

Generated C inspection confirms that `FieldId` and
`ResolvedFieldIdentity` are emitted as unboxed `long` values throughout type
headers, accepted rows, record shapes, and typed expressions. Field identities
are absent from ARC release masks and do not retain an option box or table.

The production-shaped `bodies` benchmark was extended without increasing the
number of functions or body sessions: each target body performs repeated
resolved field accesses. Clean `-O2` before/after results with identical
fixtures and checksums were:

| Resolved field accesses per module | Baseline median | Current median | Latency | Allocations |
| --- | ---: | ---: | ---: | ---: |
| 64 | 4,372 us | 3,776 us | -13.6% | 17,514 -> 13,930 (-20.5%) |
| 256 | 17,304 us | 14,836 us | -14.3% | 65,146 -> 50,810 (-22.0%) |

The reduction scales at seven allocations per resolved field access. Headers
retain the same allocation count with a median latency delta of about +0.6%,
within noise. Accepted-graph construction adds about 0.49% transient
allocations for the mandatory relation rows, while its median latency improved
about 3.2%; retained objects and bytes were unchanged.

Validation completed:

- focused field/decl/JSON/CTFE/Core suites: 664 tests passed;
- semantic-index focused leak suite: 18 tests passed with zero per-test leaks;
- `scripts/compiler-check --stage typecheck`: 43 sources, 37 suites, and 2
  special checks passed;
- `scripts/compiler-check --changed`: 16 sources, 24 suites, and 4 special
  checks passed, including Core sanitizers, compiler tools, declaration
  boundaries, and the leak gate; and
- full `compiler-blorp` plus `compiler-blorp-sanitize`: 8,021 tests passed
  (4,360 ordinary and 3,661 ASan/UBSan), zero failures.

Final diffstat is separated by ownership: production `+725/-173` (net +552),
tests `+417/-81` (net +336), benchmark fixtures `+27/-5` (net +22), and docs
`+100/-9` (net +91). The production increase is the explicit identity cutover
across typed AST, accepted authority, CTFE/Core consumers, category validation,
and boundary projection; no compatibility layer or duplicate old field-ID
path remains.

## Stop Conditions

Stop and consult before:

- changing record/tuple layout or field resolution semantics;
- fabricating field IDs for tuples, recovery, or builtins;
- retaining raw and typed field IDs together;
- storing parent type/table/path on every field occurrence;
- changing external schemas;
- adding a cache or invalidation; or
- broadening into globals, traits, implementations, semantic type interning,
  or Core field layout.
