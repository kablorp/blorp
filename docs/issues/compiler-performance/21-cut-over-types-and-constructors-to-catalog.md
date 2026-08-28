# Cut Over Type And Constructor Queries To The Declaration Catalog

**Status:** Alias vertical slice accepted; record vertical slice implemented and measured

## Context And Dependencies

Issue 20 rejected the additive full-catalog design. The active implementation
retains only a graph-owned canonical `TypeAliasIndex`, then attaches a
demand-built local/selective overlay to the selected module's existing opaque
`ModuleView`. Accepted alias reads use that authority and accepted alias headers
are no longer published to `Env`. Provisional pre-acceptance work retains the
legacy environment path.

The alias sub-slice is the first authority cutover. This issue continues the
same vertical pattern for records, unions, constructors, type homes, known
resource facts, and type-containment facts. Those remaining categories are
still installed into and read from `Env`; the alias result must not be described
as a complete type/constructor cutover.

The second vertical slice now moves accepted record declarations and field
metadata to a graph-owned `RecordTypeProjection`. It deliberately reuses
`AcceptedRecordHeader`, resolved field shapes, containment facts, and bound
module identities from the accepted type-header graph. It does not parse or
infer record declarations again.

## Implemented Record Vertical Slice

### Authority And Lifetime

`complete_typecheck_graph` builds one canonical public `RecordTypeIndex` and
one module overlay per bound module. The overlays are keyed privately by
`module_identity_storage_key`; callers query with typed `ModuleIdentity`.
Normal, recoverable, and CTFE artifact module preparation perform one lookup
rather than rescanning headers or reconstructing persistent dictionaries.

Each module overlay contains:

- local public and private records under source spelling;
- public records from explicit direct imports as record-literal candidates;
- precomputed field-name-set keys for unannotated record inference; and
- the shared canonical public index as exact-lookup fallback.

Transitive accepted records remain available by canonical exact name without
becoming unqualified record-literal candidates. Ambient implementation modules
are excluded unless they are also explicit source imports. Selective type
spellings continue to use the existing `TypeAliasIndex`; record projection does
not create a competing alias authority.

Projection construction rejects duplicate names. Accepted installation also
checks that the expected record exists in the selected index before publishing
type-home and containment facts. A missing module projection or record produces
a deterministic internal typecheck error; it does not fall back to `Env`.

### Production Reads

Accepted record authority now serves:

- exact record field metadata and generic substitution;
- annotated record literals and record updates;
- ordinary and callable field access;
- unannotated record inference by exact field-name set;
- record branches of resource/function/stream capability traversal;
- value-struct classification for foreign argument validation; and
- accepted declaration-time record-name existence checks.

Accepted record headers no longer publish `RecordSymbol` values into body
`Env`. They still publish the compact containment cache and type-home facts;
those are separate later Issue 21 categories. Provisional header work retains
the complete legacy record installation path.

### Correctness Evidence

Focused coverage includes:

- local accepted literals, updates, and field access with no record in `Env`;
- provisional local records remaining in `Env`;
- generic and canonical imported record field metadata;
- imported return-record field access without importing the record name;
- selective record aliases and qualified record types;
- recoverable normal and CTFE artifact modules using the same record authority;
- duplicate/fallback/ordering/containment behavior in the opaque index; and
- existing module-view stripping semantics.

The public typecheck stage remains the authority for private import,
resource-source, one-shot stream, function-carrier, and diagnostic fixtures.

### Record Slice Production Replay

Three order-balanced alternating baseline/candidate pairs used one captured
compiler CLI target-only typecheck request. Every measured row was verified and
produced the same 2,029,527-byte response with SHA-256
`27bd1660c16a36e99ace6f7a89a0c37680385484639d7b72a5e7ac96f12463b1`.

| Metric | Alias-only baseline | Record authority candidate | Delta |
| --- | ---: | ---: | ---: |
| Median elapsed | 43.711 s | 42.098 s | -3.69% |
| Median named typecheck checkpoints | 23.068 s | 21.205 s | -8.08% |
| Allocations | 264,090,833 | 259,882,862 | -1.59% |
| Releases | 255,082,207 | 250,825,723 | -1.67% |
| Current objects | 9,023,077 | 9,071,413 | +0.54% |
| Allocator bytes | 699,923,872 | 706,800,896 | +0.98% |
| Median peak sampled RSS | 1,053,655,040 B | 1,062,273,024 B | +0.82% |

The retained module overlays trade less than one percent additional retained
allocator memory for eliminating repeated normal/CTFE projection construction
and accepted record-symbol materialization. This stays below the 3% retained
memory gate while producing material checkpoint and allocation reductions.

### Remaining Issue 21 Work

Union declarations, constructors, type homes, known type facts, and the
accepted containment cache remain on their existing paths. The next mergeable
slice moves union metadata only; constructor lookup remains separate because it
has additional source-name, identity, collision, and pattern precedence rules.

Types are intentionally migrated before callables and implementations. Their
visibility is broad: accepted semantic types may refer to canonical types from
transitive dependencies even when the corresponding values are not imported.
That makes this category the strongest test of the module-view model while
still leaving callable resolution unchanged for the next issue.

## Problem Statement

The current frontend repeatedly converts graph declarations into scope
symbols. Each module receives local and imported type facts, and each union can
publish several constructor symbols. Persistent scope updates copy collection
structure at each insertion. Across a large graph this turns accepted
declarations into repeated work and retained duplicate data.

Keeping both catalog reads and legacy `Env` reads indefinitely would be worse:
it would increase memory, duplicate invariants, and allow the two authorities
to disagree. This issue must move one complete declaration category and delete
its old graph-owned storage as each query family is migrated.

## Goal

After this issue:

1. graph-owned type and constructor declarations have one authority: the
   accepted declaration catalog;
2. module visibility is decided by category-specific projections attached to
   the existing opaque `ModuleView`;
3. lexical body-local type parameters and refinements remain in `Env`;
4. imported and top-level graph types are no longer installed into module
   scopes for body checking;
5. every migrated query fails closed on missing, wrong-category, or ambiguous
   catalog references; and
6. structural counters prove that legacy graph-type materialization is zero.

## Non-Goals

- Do not migrate functions, globals, traits, implementations, overloads, or
  UFCS candidates. Issue 22 owns those categories.
- Do not redesign type inference or semantic-type representation.
- Do not add a fallback from a failed catalog lookup to the legacy `Env`.
- Do not flatten module visibility into one global source-name dictionary.
- Do not replace lexical scope handling.

## Required Lookup Semantics

Write the precedence contract down in tests before changing production reads.
At minimum, preserve this ordering:

1. body-local type parameter or refinement;
2. declaration in the current module;
3. explicitly imported or aliased declaration visible in the module view;
4. qualified member selected through a module alias;
5. transitive canonical type identity when an already-accepted semantic type
   requires it; and
6. a deterministic ambiguity or not-found result.

Transitive canonical type access must not accidentally grant transitive value
visibility. Source spelling, canonical identity, and module qualification are
separate concepts and must have separate APIs.

## Phase 1: Inventory Every Consumer

Before implementation, use `rg` to inventory all production consumers of:

- `env_get_type_params` and type-parameter bounds;
- type alias lookup and expansion;
- record and union declaration lookup;
- constructor lookup by source name and nominal identity;
- known ordinary/resource type facts;
- type-home and imported-type-home lookup;
- record-field and union-variant discovery;
- type-containment or accepted-type predicates;
- imported type-header installation; and
- accepted local type-header installation.

Create a table in this issue's implementation notes with these columns:

| Consumer | Query meaning | Lexical or graph-owned | Current authority | Replacement API | Test |
| --- | --- | --- | --- | --- | --- |

Do not infer query meaning solely from function names. Read every call site and
classify whether it needs lexical scope, exact identity, unqualified source
lookup, qualified lookup, or transitive canonical access.

## Phase 2: Add Category-Specific Authority APIs

Add narrow APIs over accepted type-header products and module projections. Do
not introduce a universal declaration catalog or speculative complete module
view before a live reader needs it. Names may follow the repository's final
conventions, but the capabilities should resemble:

```blorp
pure func module_view_find_accepted_type(
	view: ModuleView,
	authority: AcceptedTypeAuthority,
	name: String
) -> Result[CatalogTypeId, DeclarationLookupError]

pure func accepted_type_authority_type(
	authority: AcceptedTypeAuthority,
	type_id: CatalogTypeId
) -> Option[AcceptedTypeDeclaration]

pure func module_view_find_accepted_constructor(
	view: ModuleView,
	authority: AcceptedTypeAuthority,
	name: String
) -> Result[CatalogConstructorId, DeclarationLookupError]
```

Use nominal category IDs. A type ID must not be reinterpretable as a
constructor ID through a public generic bridge. Exact identity lookup should
be direct; source-name lookup may return a typed ambiguity result.

The APIs must not materialize a new list on every exact lookup. If ordered
candidate projection is required, keep stable catalog order and measure its
allocation behavior separately.

## Phase 3: Migrate In Small Category Commits

Perform the cutover in this order:

1. type aliases and alias expansion;
2. record declarations and record fields;
3. union declarations and variants;
4. constructor exact-identity lookup;
5. constructor unqualified and qualified source lookup;
6. type-home facts;
7. known ordinary/resource type facts;
8. accepted type-containment predicates;
9. selective and qualified imported-type lookup; and
10. remaining local top-level type queries.

The first commit also owns Issue 20's initial graph-retention work. It retains a
canonical `TypeAliasIndex` plus demand-built module overlays rather than a
complete declaration catalog. It is accepted only if alias reads are
module-view-backed and alias symbols are removed from the body environment in
that same commit. Do not merge broader catalog retention while its production
lookup remains legacy-authoritative.

For each step:

1. add or update a focused behavior test;
2. route the production consumer through the accepted category authority;
3. remove the corresponding graph-owned `Env` field, symbol insertion, or
   adapter immediately;
4. add a stale-symbol scan for the removed path; and
5. run the focused tests before moving to the next family.

Do not accumulate a branch where all reads are dual and cleanup is deferred to
the end.

## TDD Coverage

Add focused tests for:

- local type shadows imported type;
- explicit alias resolves to the correct nominal type;
- qualified and selective imports remain distinct;
- transitive canonical type is available without transitive value visibility;
- duplicate visible type names produce the same deterministic diagnostic;
- record fields and union variants preserve declaration order;
- generic aliases preserve type parameters and bounds;
- constructors preserve IDs, owner union, payload shape, visibility, and
  source span;
- private imported types and constructors remain inaccessible;
- resource types retain cleanup/home metadata;
- builtin types keep their explicit origin/category;
- malformed, missing, and wrong-category catalog IDs fail closed;
- rejected declarations do not enter the accepted catalog;
- error recovery does not publish partially accepted types; and
- nested lexical type parameters still shadow graph declarations correctly.

Prefer tests that compare old and new observable results before deleting the
old path. Once authority moves, retain expected outputs rather than a permanent
legacy implementation oracle.

## Structural Counters

Extend the Issue 15 observation surface with:

```text
catalog_type_exact_queries
catalog_type_name_queries
catalog_constructor_exact_queries
catalog_constructor_name_queries
catalog_type_query_candidate_visits
legacy_imported_type_symbol_installs
legacy_imported_constructor_symbol_installs
legacy_local_graph_type_symbol_installs
legacy_local_graph_constructor_symbol_installs
```

The final structural assertions are:

```text
legacy_imported_type_symbol_installs == 0
legacy_imported_constructor_symbol_installs == 0
legacy_local_graph_type_symbol_installs == 0
legacy_local_graph_constructor_symbol_installs == 0
catalog_type_exact_queries > 0
catalog_constructor_exact_queries > 0
```

Exact query candidate visits must remain constant as unrelated modules are
added. Unqualified source-name query work may scale with actual same-name
candidates, not total graph declarations.

## Performance Measurement

Rerun the Issue 15 synthetic matrix. Include graphs with:

- many modules and few declarations;
- few modules and many declarations;
- unions with 0, 1, 16, 64, and 256 variants;
- repeated type names across modules; and
- deep import chains with transitive type references.

Record authority/projection build cost separately from body query cost. Then run at
least three alternating baseline/candidate production typecheck replays against
one captured compiler request. Require byte-identical responses.

Report:

- typecheck checkpoint time;
- end-to-end replay time;
- allocation and release counters;
- current objects and allocator bytes;
- peak RSS;
- authority/projection retained size; and
- all structural counters above.

## Verification

Run at minimum:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_env.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_state.brp
./blorp test --timeout 180 compiler/tests/test_compiler_typecheck_decl.brp
./blorp test --timeout 180 compiler/tests/test_compiler_type_occurrence.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp-sanitize
scripts/test leak
```

Also run all public should-pass/should-fail fixtures involving aliases,
records, unions, constructors, privacy, selective imports, and qualified
imports. Assert exact diagnostics where the test contract supports them.

## Acceptance Criteria

Accept only if:

1. one accepted category-authority path is authoritative for every graph-owned type and
   constructor query;
2. lexical type facts remain correctly scoped in `Env`;
3. all legacy graph type/constructor installation counters are zero;
4. exact lookup work is independent of unrelated graph size;
5. diagnostics, identity assignment, and declaration ordering are unchanged;
6. production replay responses are byte-identical;
7. peak RSS does not regress materially; and
8. focused and broad ownership/typecheck gates pass.

## Valid Merge Point

This issue is a valid merge point when types and constructors have exactly one
authority while callable/global/trait/implementation categories remain wholly
on the legacy path. The next issue must not be required for correctness.
