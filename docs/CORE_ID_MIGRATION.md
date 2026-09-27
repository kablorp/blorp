# ID-First Compiler Migration

Goal: after the compiler has resolved a source name, later phases operate on a
typed integer identity. Source spellings live once in immutable display tables
and are consulted only for diagnostics, dumps, reflection, foreign/exported
ABI, and optional readability of generated artifacts. No later phase should
reconstruct semantic identity from a `String`.

This is a migration plan, not permission for a big-bang rewrite. It uses a
thin ID spine followed by a moving deletion frontier:

1. mint authoritative IDs at the earliest phase that can know the entity;
2. propagate those IDs to C emission while strings still exist as a checked
   compatibility representation;
3. make emission and late Core consume IDs;
4. move backward one phase boundary at a time, deleting strings and
   name-keyed indexes only after every consumer on the later side has moved;
5. retain one ID-to-display-facts path for the few operations that genuinely
   need a source spelling.

Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) before working a cut. Its
setup, measurement, foreground-gate, and landing rules apply. Related plans
remain authoritative for their own data: [`FRONTEND_FACTS_ROADMAP.md`](FRONTEND_FACTS_ROADMAP.md)
for immutable stage facts, [`TYPE_INTERNING_ROADMAP.md`](TYPE_INTERNING_ROADMAP.md)
for semantic types, and [`CORE_NODE_TABLE_ROADMAP.md`](CORE_NODE_TABLE_ROADMAP.md)
for expression identity. This roadmap owns source-name, value-definition,
binding, and emitted-symbol identity and the boundaries between them. In
particular, A11 is the sole owner of parser/source-name consolidation; the old
Type Interning I6 proposal is delegated here so two migrations cannot invent
competing name tables.

## Why this order

Starting by deleting strings from parsing or typechecking would force every
later phase to change at once. Starting at emission alone is also insufficient:
locals and pass-generated binders do not yet have a complete identity contract.
The thin-spine approach makes both directions meet:

```text
parsed graph -> definition/body identities -> typed graph -> Core -> emission
                    |                                        |
                    +---------- display facts ---------------+

first:  carry IDs all the way forward
then:   remove operational strings from right to left
```

The reverse index is not a final cleanup step. It is created when an ID is
minted, so no phase ever needs to reconstruct a spelling or retain a duplicate
one. The index remains cold data; hot identity tests compare only scalars.

## Current foundation and gaps

The compiler already contains much of the foundation:

- Stage 4 owns `ModuleId` and a validated `ModuleTable`.
- Stage 6 builds a compilation-local `SourceNameTable` and exposes
  `SourceNameId`. Its own comment correctly says that a spelling ID is not a
  semantic identity.
- Stage 6's graph `DefinitionIndex` assigns `DefinitionId`, `FieldId`, and the
  typed callable/type/constructor/trait ID wrappers. Its `DefinitionTable`
  already maps a definition ID to module, kind, source name, owner name, and
  span.
- Typed calls and many typed declarations already carry exact definition IDs.
- C symbol projection already generates ordinary callable symbols from
  `def_id` rather than their source spelling.
- Core lowering gives authored local binders a positive `id`, and Core has a
  report-only binder identity check.

The important gaps are:

- `SourceNameTable` catalogs module-visible declaration spellings, not local
  parameters, local bindings, record fields, or every identifier occurrence.
- lexical scopes and typed local uses are still resolved and represented by
  `String`; `VarSymbol` has no local binding identity;
- `CoreVar` is the heap-managed record
  `{ name: String, id: Int, def_id: Option[Int] }`;
- the current Core `id` is only function-local and is not sufficient by itself
  outside its owning function;
- match bindings and many synthetic Core passes still use `id = 0` or bake
  uniqueness into generated strings;
- `CoreProgram` drops the frontend `DefinitionTable` at graph preparation, so
  later stages cannot use the existing canonical ID-to-name table;
- local C names still come from `c_local_name(variable.name)`;
- Core and backend still contain semantic decisions made from source spelling,
  including intrinsic/runtime recognition and several name-keyed ownership
  catalogs.

A source census on `main` at `afc4dcfd` found 120 `Dict[String` occurrences
in typecheck, 63 in Core lowering, 185 in Core, and 231 in the backend. It
also found 50 files mentioning `CoreVar` and hundreds of broad
`variable.name`/`binding.name`/`param.name`-shaped sites in Core and backend.
These are triage counts, not a claim that every occurrence is wrong: type
rendering, C templates, foreign symbols, and user data legitimately use
strings. C0a below produces the classified census and C0b adds dynamic weight.

### Phase contract: strings stop at resolution

The intended steady-state boundary is precise:

1. module discovery issues `ModuleId` and installs every module-visible
   declaration into the canonical definition table;
2. immediately after discovery/surface installation, every declaration has a
   typed definition/member ID before any body is inferred;
3. immediately before a body is inferred, its lexical resolver issues local
   value IDs and resolves authored use sites once;
4. inference and every later phase consume those IDs. A spelling may still be
   carried temporarily during migration, but it is display/assertion data and
   never the authority;
5. unresolved name lookup, diagnostics/formatting, reflection, and explicit
   ABI projection are the only string/name-ID boundaries that remain.

“After discovery” therefore does not mean assigning locals before their body
is walked. It means definitions are ID-only at the graph boundary, and each
body crosses one explicit lexical-resolution boundary before semantic work.
No later pass repeats discovery or lexical resolution.

## Identity vocabulary

Do not use one untyped `Int` for unrelated identity domains. The issuing phase
and meaning of each identity must remain visible in the type.

| Identity | Issuer | Meaning | Lifetime |
| --- | --- | --- | --- |
| `ModuleId` | module discovery | one validated module in a graph | frontend snapshot |
| `SourceNameId` | source-name catalog | one spelling, not one entity | frontend snapshot |
| `DefinitionId` | definition index | callable, type, constructor, field, global, trait, or implementation | compilation artifact |
| `DefinitionValueId` | checked definition-table projection | a definition that denotes a runtime value or owns an executable body | compilation artifact |
| `BuiltinValueId` | builtin enum/catalog | a builtin value below the graph definition range; never a local owner | compiler ABI |
| `ResolvedValueId` | body resolver or Core minting API | one definition value or authored/synthetic local binder | typed frontend through backend |
| `ResolvedNameSiteId` | body resolver | one authored identifier occurrence within a body snapshot | resolved frontend artifact |
| `ResolvedTypeNameSiteId` | module resolver | one type-name occurrence within a module snapshot | resolved frontend artifact |
| `ResolvedMemberNameSiteId` | module resolver | one member-name occurrence within a module snapshot | resolved frontend artifact |
| `NodeId` | Core construction | one Core expression occurrence | Core artifact |

`SourceNameId` may be used for spelling equality and unresolved lookup. It
must never replace `DefinitionId` or `ResolvedValueId`: two shadowed locals and two
overloads may share one spelling while naming different entities.

### Core value identity

The recommended Core representation is a fixed-layout pair:

```blorp
struct ResolvedValueId {
	owner_definition_id: DefinitionValueId,
	local_ordinal: Int
}
```

The constructors and projections belong in one identity module:

```blorp
private DEFINITION_VALUE_ORDINAL: Int = 0

pure func resolved_definition_value_id(definition_id: DefinitionValueId) -> ResolvedValueId:
	{
		owner_definition_id = definition_id,
		local_ordinal = DEFINITION_VALUE_ORDINAL
	}

pure func resolved_local_value_id(
	owner_definition_id: DefinitionValueId,
	ordinal: Int,
) -> ResolvedValueId:
	-- Construction rejects/reserves zero; callers cannot fabricate the
	-- definition-value representation for a local.
	{
		owner_definition_id = owner_definition_id,
		local_ordinal = ordinal
	}
```

`DefinitionValueId` is created only by a checked projection over a
`DefinitionTableRow` or by the post-frontend definition minting API. Callable,
constructor, and global rows are value definitions; type, field, trait, and
implementation rows cannot be passed to these constructors. The unchecked
raw-`Int` constructor is private to the authority module.

The definition-index seed reserves IDs below
`DefinitionTable.first_graph_definition_id` for builtins, and the frozen table
does not contain rows for them. C0a classifies which of those values survive
into typed/Core value references. A surviving builtin gets a checked
`BuiltinValueId` from the builtin enum/catalog and an explicit intrinsic or
runtime symbol policy; it cannot own local ordinals. A builtin already lowered
to a dedicated operation has no `ResolvedValueId`. Do not pad the graph/local
frontier down to zero or fabricate frontend table rows for builtin types and
traits.

Slot zero denotes the definition value itself. Positive slots denote local
binders owned by an executable value definition. The pair is artifact-wide identity without a global
mutable binding counter:

- an authored body resolver assigns ordinals deterministically in source walk
  order;
- nested lambdas share their containing definition's ordinal namespace until
  closure conversion creates a new function;
- a cloned function receives a new definition ID and therefore a new identity
  namespace even if its local ordinals are preserved;
- a pass that adds a binder inside an existing function mints the next ordinal
  for that owner;
- a pass that copies a binding inside the same function must mint a new ordinal;
- globals, callables, and constructors use ordinal zero with their checked
  `DefinitionValueId` projection.

The type belongs in a phase-neutral stage-6 identity/storage module so the
typed frontend does not import a Core-owned type. Core uses the same
`ResolvedValueId`; it does not define an isomorphic wrapper or conversion.
The exact source type may be opaque over this struct. What matters is that it
remains fixed-layout, has smart constructors, and has no public sentinel
manipulation. Do not encode the pair into bit ranges, signs, source offsets,
hashes, or string prefixes.

### Display facts

Semantic values do not carry display strings. Tables own them:

```blorp
-- Stage 6: no Core imports.
record AuthoredBindingDisplayFacts {
	id: ResolvedValueId,
	spelling: String,
	location: SourceLocation
}

record AuthoredIdentityFacts {
	bodies: List[ResolvedBodyNames],
	body_row_by_owner: DefinitionValueRowIndex
}

-- Stage 9: Core-owned generated provenance.
record SyntheticBindingDisplayFacts {
	id: ResolvedValueId,
	kind: SyntheticBindingKind,
	location: CoreSourceLoc,
	display_name: String
}

record GeneratedDefinitionDisplayFacts {
	id: DefinitionValueId,
	origin_definition_id: Option[DefinitionValueId],
	kind: GeneratedDefinitionKind,
	location: CoreSourceLoc,
	display_name: String
}

record CompilerIdentityFacts {
	definitions: DefinitionTable,
	authored: AuthoredIdentityFacts,
	generated_definitions: List[GeneratedDefinitionDisplayFacts],
	synthetic_bindings: CoreBindingDisplayCatalog
}
```

The phase-neutral ID types and checked frontend projections live in
`stage_06_typecheck/graph/resolved_value_identity.brp`. Authored rows and their
builder live in `stage_06_typecheck/graph/authored_identity_facts.brp` and use
only `SourceLocation`. Each body check publishes one immutable
`ResolvedBodyNames` into both accepted and recovered body outcomes, so
the reusable `BodyOutcomeTable` never loses identity facts when it bypasses
inference. Graph materialization orders those canonical body tables by the
accepted body plan and builds only the outer owner index; it does not copy
their rows or strings. Core's generated-definition/synthetic-binding rows,
catalog view, and allocator state live in `stage_09_core/identity.brp` and may
use `CoreSourceLoc`. The Core catalog view queries synthetic rows first and
then the borrowed authored catalog; it does not copy authored rows or move Core
types into stage 6.

`TypecheckedGraph.definition_table` remains the sole stage-6 definition
authority. `AuthoredIdentityFacts` contains authored body identity facts
(binding display, name-site, and target tables) and never embeds or aliases the
definition table. C3c graph preparation consumes the graph's
existing `definition_table` and `authored_identity_facts` fields into the one
`CoreIdentityState`; the prepared Core product does not retain a second
top-level definition-table field. `CompilerIdentityFacts` is a borrowed
read-only projection of that Core state, not separately stored data.

The frontend table remains frozen. Core-created definitions are appended to a
separate overlay in exact `next_def_id` order. Resolving a display row first
checks the frontend table's contiguous range, then the generated overlay's
contiguous range. A missing row produces an internal diagnostic containing the
numeric ID and provenance; it never falls back to a guessed or source-spelling
lookup. Minting a post-frontend definition must atomically consume
`next_def_id`, append this display row, and append its local-ordinal frontier.
No pass may increment `next_def_id` directly after A4.

The authored and Core display catalogs above are logical interfaces. The
authored carrier defaults to nested immutable body tables because
`BodyOutcomeTable` is reusable and may remain live beside the final graph.
C1b compares that with a flattened row/range view, but the workload must
include seeded-body reuse and count any row/string retains or copies caused by
the simultaneous outcome and graph lifetimes. A flat carrier is acceptable
only if it preserves one logical authority and wins that measurement. Core's
generated catalog separately compares flat rows/ranges and nested owner
tables. Every choice reports exact construction allocations and generated-C
ownership. Before choosing the catalog's carrier,
also run C1b's pass-state representation probe. A4 requires one
`CoreIdentityState` authority to survive every pass and handoff, so the chosen
opaque carrier must add no per-pass allocation and no material retain/release
traffic to ordinary program-only state updates. If none of the probed physical
layouts meets that requirement, stop at C1b and redesign the carrier; do not
proceed with a parallel top-level catalog and pass-local allocator, and never
copy strings back onto nodes.

Initially `AuthoredBindingDisplayFacts` may retain one canonical `String` per
binder. A11 replaces it with `SourceNameId`. That keeps the identity
migration independent of parser/lexer interning while still reducing strings
from every occurrence to one per binder.

### Normalized table contract

The compiler should expose resolved information as normalized logical tables
whenever the data outlives the walk that discovers it. “Normalized” is a
semantic contract, not a requirement to allocate a heap record for every row
or to use one physical representation everywhere.

Every new or migrated fact family follows these rules:

1. One table is authoritative for each entity or fact. A consumer may build a
   derived index, but that index stores row numbers or IDs and can be rebuilt
   from the authority.
2. Primary and foreign keys use the narrow typed ID for their domain. A source
   spelling, location, or traversal position is never a substitute key once an
   ID exists.
3. One-to-many data uses an owner range or an edge table. Many-to-many data
   uses an explicit edge table whose key states the cardinality.
4. Optional facts that apply to a minority of entities live in sparse
   satellite tables. Do not add several `Option` fields to every hot row.
5. Builders are local and uniquely owned. Publication freezes the columns,
   ranges, and derived indexes together; readers borrow the resulting facts.
6. Logical normalization comes before physical layout. After the schema and
   queries are fixed, measure row records, parallel columns, ranges, and dense
   or sparse indexes behind the same API.
7. Deliberate denormalization is allowed only for a named hot query with
   retained generated-C and allocation/instruction evidence. Document the
   duplicated fact, its authority, and the check that keeps it synchronized.

For example, do not make a resolved use row repeat its spelling, source path,
module name, and definition record:

```blorp
-- Wrong: identity, display, and ownership are copied into every use.
record ResolvedUse {
	spelling: String,
	module_path: String,
	definition: DefinitionTableRow,
	location: SourceLocation
}

-- Logical normalized schema. The hot row is narrow; display data is joined
-- only by diagnostics and tooling.
record NameUseSiteTable {
	locations: List[SourceLocation]             -- row key: ResolvedNameSiteId
}

record ResolvedValueUseTable {
	name_site_ids: List[ResolvedNameSiteId]      -- unique FK
	value_ids: List[ResolvedValueId]            -- FK to value authority
	row_by_name_site_raw: Dict[Int, Int]        -- derived lookup index
}

record AuthoredBindingDisplayTable {
	value_ids: List[ResolvedValueId]             -- unique FK
	spellings: List[String]                      -- one display value per binder until A11
	locations: List[SourceLocation]
	row_by_value_id: ResolvedValueRowIndex       -- private derived index
}
```

The parallel columns above illustrate a likely allocation-friendly carrier;
they do not prejudge the measurement. A `List[ResolvedValueUseRow]` can satisfy
the same logical schema if it generates better code. What is not acceptable is
two independently mutable authorities or a compatibility record that copies
the joined data back onto every node.

`ResolvedValueRowIndex` and `DefinitionValueRowIndex` are opaque private
carriers whose public APIs accept the corresponding typed IDs. C1a guarantees
checked construction and equality only; it
does not silently require generic `Hashable` for the fixed-layout struct. The
representation probe compares a nested owner-raw/local-ordinal index, owner
ranges, and a dense row map. Likewise, location ingress uses an explicitly
named scalar projection from `source.brp` and a private `Dict[Int, Int]`, not a
`Dict[SourceLocation, ...]` that the current opaque type cannot instantiate.
Adding `Hashable` later is a separate API decision with equality/hash tests and
a generated-C probe for generic struct-key boxing.

Use this notation in implementation issues:

```text
NameUseSite(name_site_id PK, location)
ResolvedValueUse(name_site_id PK/FK, value_id FK)
AuthoredBindingDisplay(value_id PK/FK, source_name_id FK, location)
```

The relational notation shows the A11 final schema. Before C11a, its physical
display column is the transitional canonical `spelling: String`; C2a can
publish it without minting a local `SourceNameId`. C11a replaces that one
column with `source_name_id FK` and deletes the strings without changing value
or row identity.

It makes ownership, uniqueness, and join direction reviewable before code is
written. The issue must also list the hot queries so a worker knows which
indexes are required and which joins must remain cold.

## Binding rules

The following invariants become strict before strings leave Core:

1. Every definition has exactly one `DefinitionId` issued by the canonical
   graph definition table or by the shared post-frontend definition allocator.
2. Every authored local binder has one positive local ordinal within its
   owning definition.
3. Every local use carries the exact `ResolvedValueId` chosen by lexical resolution;
   it never repeats a scope-chain lookup after that point.
4. Every synthetic binding has an ID minted by the owning Core pass.
5. Cloning into a new definition remaps the owner component. Cloning within
   the same definition freshens the local ordinal.
6. Definition references carry ordinal zero and a validated definition ID.
7. No semantic comparison combines a spelling with an ID. Equality is the ID.
8. A lookup from ID to spelling is legal only at a named display, diagnostic,
   serialization, reflection, or ABI boundary.
9. A missing display row never changes semantics. It is an internal diagnostic
   defect, not permission to fall back to name-based resolution.
10. IDs are compilation/snapshot-local. Stable external APIs use source or ABI
    identity, not a persisted compiler integer.

## Working method for every cut

Each cut follows the same loop:

1. Write a characterization or regression test first.
2. Record the exact source-shape census for the target family.
3. Record a baseline on a frozen self-compile and, when practical, a small
   retained fixture that isolates the target.
4. Add or switch one authority. During A3-A8 the compatibility fields may
   coexist with identity, but each migrated consumer reads exactly one path;
   it never falls back from ID to name. Record the remaining legacy consumers
   in the census.
5. Assert compatibility at the migration seam in debug/check-invariant mode.
6. Remove the superseded field, index, wrapper, or fallback in the same cut.
7. Rerun the narrow loop, identity oracle, and proportionate gates.
8. Keep a performance cut only with mechanism-matched evidence. A flat
   correctness/enabling cut may land if it simplifies the model and regresses
   neither whole-compile retired instructions nor allocations by more than
   0.5% across matched samples. This is a series budget, not permission to
   compound a 0.5% regression in every cut: a neutral enabling cut names the
   paying consumer in the same integration wave, and the completed wave must
   be flat or better against its green starting checkpoint.

Do not build indexes of full declarations or expression bodies. Tables hold
IDs, row indices, scalar facts, and display metadata; consumers read mutable
bodies from the current program. This avoids the previously measured stale
body and non-unique-list failures of the parked program-facts/definition-table
attempts.

### Required worker handoff

The roadmap is not a sufficient handoff by itself. Before assigning a cut,
the orchestrator supplies a bounded implementation brief with every row below.
If a row is unknown, the worker performs a named probe and reports back before
changing production code; it does not fill the gap with an inferred design.

| Handoff item | Required content |
| --- | --- |
| Green base | exact revision and worktree/branch |
| Merge value | one sentence naming the lookup, copy, allocation, semantic fallback, or compatibility path removed by this cut |
| Authority switch | the authoritative representation before and after the cut; name the old path deleted in the same train |
| Logical schema | normalized tables with typed primary/foreign keys, cardinality, sparse satellites, and derived indexes |
| Literate implementation | compact before, builder, consumer, and deletion snippets with prose explaining ownership and phase boundaries |
| File ownership | exact production/test files the worker may edit and adjacent files that are explicitly out of scope |
| First failing test | fixture and assertion that fail before the implementation |
| Fast loop | smallest command plus the counter/phase row that isolates the claimed mechanism |
| Acceptance | exact correctness oracle, ratchet change, allocations/instructions budget, and required deletion |
| Stop/consult conditions | surprising COW, new authority, cross-phase dependency, schema mismatch, or performance tradeoff that requires orchestration guidance |

Code in a handoff is contractual pseudocode: names may adapt to local style,
but keys, ownership, state transitions, and the deleted path may not silently
change. Prefer a short literate sequence over a large final-state type dump:

1. show why the current code repeats work or copies state;
2. show the uniquely owned builder and the point at which it freezes;
3. show one hot consumer reading a narrow table by ID;
4. show the old lookup/field/helper being deleted.

#### Worked design example: C2a parameters and straight lets

This section demonstrates the required authority, schema, ownership, and
consumer/deletion sequence. It is deliberately not a dispatchable handoff:
the orchestrator must add the current green revision/worktree, exact owned and
out-of-scope file list, a named failing fixture and assertion, and the literal
smallest command from that revision. Never send a worker this section alone or
label placeholders such as “the focused fixture” complete.

**Merge value.** Resolve parameter and straight-let uses once per body and
delete their repeated local scope-chain lookup during inference.

**Authority before.** Each inference read searches `Env` by spelling. The
scope's symbol collection is the authority, but callers cannot name the exact
binding they already resolved:

```blorp
-- Before: every occurrence repeats lexical selection by String.
private pure func infer_name_expr(
	context: InferContext,
	name: ParsedIdentifier,
) -> InferResult:
	match lookup_bare_value(context, name):
		Some(BareEnvSymbol(symbol)):
			infer_env_symbol_name_expr(context, name, symbol)
		other:
			infer_non_local_bare_value(context, name, other)
```

**Authority after.** One resolver walk publishes body-local site and target
tables. The location index is a derived ingress for the source tree; inference
then uses the exact `ResolvedValueId`.

```text
BodyNameUse(name_site_id PK, location, migration_state)
LocalNameUseTarget(name_site_id PK/FK, value_id FK)
AuthoredBinding(value_id PK, spelling, location)
```

`spelling` is the one transitional display value per binder; A11 replaces it
with `source_name_id FK` without changing the value-identity joins.

```blorp
enum BodyNameUseMigrationState:
	ResolvedLocalBodyNameUse
	LegacyConsumerLocalBodyNameUse
	NonLocalBodyNameUse

record BodyNameUseTable {
	locations: List[SourceLocation]
	migration_states: List[BodyNameUseMigrationState]
	site_by_location_raw: Dict[Int, Int] -- derived through source_location_identity_key
}

record AuthoredBindingBatch {
	value_ids: List[ResolvedValueId]
	spellings: List[String] -- display-only transition until A11
	locations: List[SourceLocation]
}

record LocalNameUseTargetTable {
	name_site_ids: List[ResolvedNameSiteId]
	value_ids: List[ResolvedValueId]
	target_row_by_name_site_raw: Dict[Int, Int] -- derived
}

record ResolvedBodyNames {
	owner_definition_id: DefinitionValueId
	bindings: AuthoredBindingDisplayTable
	name_uses: BodyNameUseTable
	local_targets: LocalNameUseTargetTable
}

private record ResolvedBodyResolutionDraft {
	owner_definition_id: DefinitionValueId
	bindings: AuthoredBindingBatch
	name_uses: BodyNameUseTable
	local_targets: LocalNameUseTargetTable
}
```

C2a owns a narrow `source_location_identity_key` projection in
`blorp/src/lib/source.brp`. It returns the exact packed opaque `Int` used by a
valid authored `SourceLocation`; it is not a hash. Tests prove equal locations
yield equal keys and every pair of unequal valid authored extents yields
unequal keys. Compiler-prelude/recovery locations are excluded before the
projection. The projection exists only to index the body-local site table and
does not expose path/module display facts. Inspect generated C to prove the
`Dict[Int, Int]` key remains scalar. Do not add `Hashable` to
`SourceLocation`/`ResolvedValueId` or use a generic struct key in this cut.

The three states prevent a partially migrated binder family from being
mistaken for a non-local use. C2a assigns IDs to every lexical binder the walk
encounters. Parameters and straight lets are marked
`ResolvedLocalBodyNameUse`; later binder families remain explicit
`LegacyConsumerLocalBodyNameUse` until C2b/C2c convert their consumers. Both
local states have an exact target row. A legacy local may call only the old
local lookup; it cannot fall through to import/global resolution or bind to a
same-spelled migrated outer variable.

```blorp
enum ResolverLocalConsumerState:
	ResolvedLocalConsumer
	LegacyLocalConsumer

struct ResolverLexicalBinding {
	value_id: ResolvedValueId
	consumer_state: ResolverLocalConsumerState
}

-- The builder is local, mutable, and uniquely owned for one body. Entering a
-- binder records the previous mapping; leaving its scope restores it.
pure func resolve_body_names(
	definition_authority: BodyDefinitionAuthority,
	body: ParsedBody,
) -> ResolvedBodyResolutionDraft:
	var builder = new_resolved_body_names_builder(definition_authority, body)
	builder = resolve_body_into(builder, body)
	finish_resolved_body_resolution_draft(builder)
```

There is one logical authority for all resolved authored-body facts. A body
check consumes its draft's `AuthoredBindingBatch` exactly once and freezes the
display, site, and target tables together as immutable `ResolvedBodyNames`:

```blorp
private pure func publish_resolved_body(
	draft: ResolvedBodyResolutionDraft,
) -> ResolvedBodyNames:
	{
		owner_definition_id = draft.owner_definition_id,
		bindings = finish_authored_binding_display_table(draft.bindings),
		name_uses = draft.name_uses,
		local_targets = draft.local_targets,
	}
```

`ResolvedBodyResolutionDraft` is consumed by this function and is never stored
or copied. `ResolvedBodyNames` is borrowed for that body's inference and then
stored unchanged on both
`CheckedBodyArtifactRep` and `RecoveredBodyArtifactRep`, so a partial or seeded
`BodyOutcomeTable` carries the canonical rows even when materialization reuses
the body without running inference. C3b also writes selected
`ResolvedValueId`s onto typed facts; it does not replace the retained site
authority.

“Stored unchanged” describes C2-C8, when only local targets are published.
C9 explicitly versions this type and finalization protocol: it atomically
renames the unchanged four-field product to `ResolvedBodyNameInputs`, makes
that the required pre-inference fact type, and reserves `ResolvedBodyNames`
for the finalized inputs plus non-local satellite described in A9. Inference
owns a separate non-local-target builder. No worker may append to the borrowed
C2 table or construct the finalized type before inference completes.

Global initializers use the same authority but a different reusable artifact
path. C2a adds `resolved_names: ResolvedBodyNames` to both
`CompletedAnnotatedGlobalHeader` and `CompletedInferredGlobalHeader` (or to one
shared completed-global payload consumed by both variants). Fresh global
completion resolves the initializer before its required two-argument
`infer_context` call; `ReuseAcceptedGlobalBodies` reads the retained facts from
`CompletedGlobalHeaderGraph` and never re-resolves or reruns inference. This is
required because a global initializer may contain lambdas, match binders, or
other lexical scopes even though its owner is a `GlobalId` projected to
`DefinitionValueId`.

At graph materialization, a uniquely owned outer builder appends body-identity
references from function outcomes and completed global headers in canonical
definition-table order and builds `body_row_by_owner`; scheduling/completion
order is not observable. It does not flatten or copy binding rows. It freezes once into the sole
`TypecheckedGraph.authored_identity_facts: AuthoredIdentityFacts` field. Stage
8 borrows that field and never rescans typed bodies. A standalone result
retains its one `ResolvedBodyNames`, so local IDs cannot escape without
their authority. The C2a body-outcome reuse test must compare fresh and seeded
paths and prove identical identity rows/order with zero new inference sessions
on the seeded path. An analogous global test uses
`blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/global_constant_lambda_value.brp`,
completes once, reuses the completed-global
graph, and proves identical identity rows/order with zero initializer checks on
the reuse path.

`BodyDefinitionAuthority` is explicit because detached numeric IDs do not
self-diagnose cross-table joins. A graph body borrows the graph definition
table. A standalone/unindexed body builds a small artifact-local table through
the normal definition builder; it never fabricates raw IDs, and its IDs never
escape that retained artifact.

```blorp
record BodyDefinitionAuthority {
	definition_table: DefinitionTable
	owner_definition_id: DefinitionValueId
}
```

The authority's provenance is validated before joining body facts with another
artifact. Do not add provenance words to every hot ID; validate at artifact
boundaries and keep standalone IDs inside their retained artifact.

Inference receives body facts as a required borrowed input rather than
storing them back on each node or threading them inside mutable accumulators:

```blorp
record InferBodyFacts {
	definition_authority: BodyDefinitionAuthority
	resolved_names: ResolvedBodyNames
}

-- Existing fields omitted here remain exactly those in state.brp.
record InferSession {
	context: Context
	env: Env
	errors: List[String]
	diagnostics: List[TypecheckDiagnostic]
	type_shape_memo: TypeShapeMemo
	facts: InferModuleFacts
	body_facts: InferBodyFacts
}

pure func infer_context(
	state: TypecheckState,
	body_facts: InferBodyFacts,
) -> InferContext:
	session = infer_session_from_typecheck_state(state, body_facts)
	{
		state = session,
		expectation = NoExpectedValue,
		in_loop = False,
		in_debug = False,
		suppress_debug_only_reference = False,
	}

private pure func infer_name_expr(
	context: InferContext,
	name: ParsedIdentifier,
) -> InferResult:
	site_id = body_name_site(context.state.body_facts.resolved_names, name.span)
	match body_name_use_state(context.state.body_facts.resolved_names, site_id):
		ResolvedLocalBodyNameUse:
			value_id = local_name_use_target(
				context.state.body_facts.resolved_names,
				site_id,
			)
			symbol = env_lookup_resolved_local_symbol(context.state.env, value_id)
			infer_env_symbol_name_expr(context, name, symbol)
		LegacyConsumerLocalBodyNameUse:
			-- Transitional and local-only. C2c deletes this arm.
			infer_legacy_local_name_expr(context, name)
		NonLocalBodyNameUse:
			infer_non_local_name_expr(context, name)
```

`BodyInferSessionSeed` remains module-only and reusable: it does not retain
body facts from a prior task. `fresh_body_infer_session` still creates fresh
solver/diagnostic state, and the now-required two-argument `infer_context`
attaches exactly one body's borrowed facts immediately before inference.

The environment may preserve its current per-scope `List[Symbol]` authority
and expose a private snapshot-local `EnvSymbolRef(scope_from_root, symbol_row)`
index by `ResolvedValueId`. This is the default C1b candidate because flattening
all symbol records into one growing list may COW-copy a prepared environment.
The reference must remain private to `env.brp`, may not enter typed output, and
is dereferenced before the Env API returns. The existing
`env_lookup -> Option[Symbol]` compatibility API remains for not-yet-migrated
consumers; C2a deletes only the replaced parameter/let call sites.

```text
ScopeSymbol(scope_authority, symbol_row PK-within-scope, symbol)
CurrentLocalSymbol(value_id PK/FK, symbol_ref FK)
LocalSymbolUndo(scope_id, undo_ordinal PK-within-scope, value_id FK,
                prior_current_local_symbol)
```

```blorp
private struct EnvSymbolRef {
	scope_from_root: Int
	symbol_row: Int
}

private union PriorCurrentLocalSymbol:
	MissingPriorCurrentLocalSymbol
	RestorePriorCurrentLocalSymbol(EnvSymbolRef)

private record LocalSymbolUndo {
	value_id: ResolvedValueId
	prior: PriorCurrentLocalSymbol
}
```

The authoritative per-scope `symbols` list appends in insertion order. Its
`symbols_by_name[name]` derived index prepends the newest row so candidate zero
remains the active shadow. `env_lookup_resolved_local_symbol` resolves and
dereferences the private row reference without reconstructing `Symbol`.

The spelling undo log used by the resolver's `current_by_name` map is separate
from this exact-ID projection. Each Env scope owns a list of `LocalSymbolUndo`
rows. Binding or refining a value records the prior state before replacing the
row; popping a scope replays those rows in reverse:

```blorp
private pure func env_bind_local_symbol_ref(
	projection: CurrentLocalSymbolIndex,
	undos: List[LocalSymbolUndo],
	value_id: ResolvedValueId,
	ref: EnvSymbolRef,
) -> LocalSymbolProjectionStep:
	prior = match current_local_symbol_ref(projection, value_id):
		Some(previous): RestorePriorCurrentLocalSymbol(previous)
		None: MissingPriorCurrentLocalSymbol
	{
		projection = set_current_local_symbol_ref(projection, value_id, ref),
		undos = undos.append({ value_id = value_id, prior = prior }),
	}

private pure func env_pop_local_symbol_scope(
	projection: CurrentLocalSymbolIndex,
	undos: List[LocalSymbolUndo],
) -> CurrentLocalSymbolIndex:
	var result = projection
	for undo in undos.reverse():
		result = match undo.prior:
			MissingPriorCurrentLocalSymbol:
				remove_current_local_symbol_ref(result, undo.value_id)
			RestorePriorCurrentLocalSymbol(previous):
				set_current_local_symbol_ref(result, undo.value_id, previous)
	result
```

Tests cover a first bind followed by pop (remove), refinement of the same ID
followed by pop (restore), two same-spelled bindings with distinct IDs, nested
scope pops, and reverse replay of two updates to one ID.

**First failing tests.** A parameter shadowed by a straight let, a migrated
outer let shadowed by an as-yet-legacy match binder, and a detached-body
authority mismatch. Assert exact typed output/diagnostics and one target row
per local use.

**Fast loop and acceptance.** Run the focused typecheck fixture, then
`scripts/compiler-check --stage typecheck`; use a discovery-to-lowering
self-compile for resolver counters and allocations. The cut lands only when
parameter/let name lookups fall to zero, resolver counters are expected-linear,
the new facts allocate once per body, legacy-family counts are explicit, Core
and diagnostics are identical, and allocations/instructions stay within the
series budget. Any COW increase in symbol storage, ambiguous binder family, or
need to publish `EnvSymbolRef` is a stop-and-consult result.

## Delivery model: vertical slices and green checkpoints

Terminology is fixed: `A0`-`A11` name architectural stages, `C0a`-`C11b`
name executable review/implementation cuts, and `D0`-`D7` name independently
releasable deliveries and their green merge checkpoints. Branches, handoffs,
ratchet rows, and atomic landing endpoints use
only `C` labels. `A` labels explain the intended state, and `D` labels group
already-defined cuts into independently releasable deliveries; neither is an
alias for a branch task. Derived issues must preserve this A/D/C vocabulary.

The architectural order below describes dependencies, not a request
to build eleven layers of infrastructure before anything pays back. Execute it
as short vertical slices. A slice is landable only when it provides at least
one of these forms of value:

- removes a repeated name lookup, string comparison, allocation, or ARC path;
- replaces a name-based semantic decision with a checked ID decision;
- makes an existing identity invariant strict for an additional producer or
  consumer family;
- adds a reusable oracle, census, or ratchet that immediately catches future
  regressions;
- deletes a compatibility path or narrows the remaining migration census.

An API, field, or table with no active consumer is not a delivery. A bounded
preparatory refactor may be reviewed independently, but production scaffolding
lands only in the same short integration train as its first consumer. In
particular:

- C1a is reviewable on its own, but C1a/C2a is one atomic landing unit: merge
  or squash the train only when C2a's first consumer is ready. The C1b
  frontend carrier/COW probe is a hard prerequisite to C2a production edits;
  its selected frontend catalog lands in that train. C1b's Core catalog lands
  with C3c, not earlier merely because its separate representation probe
  succeeded;
- C3a/C3b/C3c are independently compiling and reviewable commits but one
  atomic landing unit. Merge or squash only the C3c endpoint; do not expose an
  intermediate main revision in which every Core variable carries unused
  transition state;
- a new resolved variant and the first consumer replacing its spelling
  predicate land together;
- every family conversion deletes or ratchets down the corresponding legacy
  allowlist in the same change.

### Rolling identity ratchet

C0a's census is also a machine-readable ratchet. It records, by family and
directory:

- unresolved/pending identity constructors;
- `LegacyConsumerLocalBodyNameUse` sites grouped by binder family;
- semantic reads of compatibility `name`/`id`/`def_id` fields;
- string-keyed semantic maps and source-spelling predicates;
- direct renderer name projection and display lookups outside allowed
  boundaries.

The initial report establishes explicit nonzero budgets. Every merged slice
must keep unrelated budgets flat and reduce at least the budget it owns. A
slice cannot add a new allowlist entry merely to pass hygiene. C11b changes the
migrated budgets from ratcheted counts to zero and turns the report into the
final strict hygiene check. This gives every intermediate merge a visible,
durable improvement even before the old fields can be physically removed.

### Independently releasable deliveries

Use the following deliveries. Work inside a delivery may be developed in parallel
from its named green checkpoint. Ordinary slices merge one at a time with their
own tests and evidence. The named C1a/C2a and C3a/C3b/C3c trains instead land
atomically at their final endpoint, with ratchet and performance acceptance
applied to that endpoint. After each landing, remaining workers rebase onto the
new checkpoint before final measurement.

| Delivery | Sequential spine | Safe parallel lanes | Value delivered at the checkpoint |
| --- | --- | --- | --- |
| D0 — observability | Land C0a census/ratchet, C0b counters, and C5a symbol-normalizer tests from one frozen input/schema | The three cuts own disjoint tooling/test files and may develop in parallel before serialized validation | Reproducible identity inventory, stronger correctness corpus, and a trustworthy generated-symbol oracle with no compiler behavior change |
| D1 — first resolved body slice | Review C1a, complete and select C1b's frontend carrier/COW probe, then merge the short C1a → C2a train so the checked vocabulary and chosen carrier land with parameters/straight lets | Resolver census/fixture work and the read-only synthetic-constructor inventory may run while C1b is measured; carrier-dependent Env/catalog production edits may not | Every authored lexical binder/use has an ID and explicit migration state; parameters/straight lets consume IDs; their inference lookup path is deleted; same-spelling IDs are checked |
| D2 — authored IDs reach Core | Extend the resolver through C2b/C2c, then merge the short C3a → C3b → C3c train | C3a's mechanical Core constructor work may be prepared while the frontend worker finishes C2b/C2c; backend symbol-plan fixtures may proceed in separate files | Every authored binding/use reaches Core by ID, lowering's local scope walk disappears, and only enumerated synthetic sites remain pending |
| D3 — strict synthetic identity | Land C4a's persistent allocator/state API, then integrate match/simple synthetics as the first producer pilot | After C4a freezes the mint/remap API, the producer families may be developed in parallel: match/simple synthetics; inlining/SSA/tail; mono/specialization/synthesis; closure/Perceus. Rebase, measure, and merge one family at a time | Each merge expands strict invariant coverage; final D3 has zero pending identities and a mandatory `ResolvedValueId` |
| D4 — ID-only Core consumers | Establish C5b's raw-identical symbol-plan seam first. Land C7a's shared final-preparation/cancellation/projection seam before branching the other C7 consumers | From C5b, backend C5c/C6x is one lane. After C7a, closure C7b, Perceus/reuse/DCE C7c, and match/tail/specialization/mono C7d may use separate workers with explicit file ownership. Serialize merges where backend files overlap | Every merge removes a name-keyed hot path or renderer policy. Final D4 has zero semantic reads of legacy `CoreVar` fields |
| D5 — representation payoff | C8 alone owns the Core variable representation flag day | Workers may prepare C9 diagnostic/formatter fixtures and disjoint C10x family censuses, but do not edit `CoreVar` concurrently | `CoreVar` and its managed string disappear; the expected Core allocation/ARC reduction becomes measurable |
| D6 — move the frontier backward | Land C9's resolved typed-frontend view, freeze the common C10x schema, then integrate one family per merge | Named types, fields/constructors, traits, and imports may be developed in parallel only with disjoint source ownership; each rebases and measures before its serialized merge | Each family removes per-occurrence strings and string-keyed semantic indexes from an earlier phase |
| D7 — one spelling authority | Land C11a source-name consolidation, then C11b makes the ratchet strict | Formatter/LSP validation and hygiene-fixture work may be prepared in parallel; the source-name authority itself has one owner | One documented spelling projection, zero migrated semantic-string violations, exact formatter/diagnostic/LSP behavior |

D1 should be the first production delivery, not merely “types exist.” D2 is
the first end-to-end spine delivery. D3 and D4 are where multiple agents can
produce independent, measurable wins continuously instead of waiting for one
large Core rewrite.

### Parallel execution rules

1. **Branch from a green checkpoint.** Give every worker the exact checkpoint
   revision, file list, first test, fast loop, metric row, and ratchet category.
2. **One owner for shared authorities.** Only the spine worker edits
   `resolved_value_identity.brp`, `identity.brp`, `ir.brp`, or the common
   catalog schema in a wave. Other workers consume the frozen API.
3. **Parallelize by consumer family, not by arbitrary files.** Closure,
   Perceus, DCE, match/tail, and backend policy are useful lanes because each
   has its own correctness oracle and phase row.
4. **Rebase before evidence.** A worker may prototype from the wave checkpoint,
   but acceptance measurements and broad gates run after rebasing onto every
   predecessor merged in that wave.
5. **Serialize expensive execution.** Agents may inspect and edit in parallel,
   but do not run compiled gates or self-compile measurements concurrently on
   macOS. Narrow source/fixture checks may run independently when they do not
   invoke competing compiler binaries.
6. **Measure both the slice and the series.** Compare each slice with its
   immediate parent, and keep a cumulative D0-to-current result so a sequence
   of individually “small” neutral regressions cannot hide a material total.
7. **Integrate value, discard speculation.** A negative experiment is recorded
   and dropped. It does not block other lanes or justify merging dormant
   infrastructure.

## Migration sequence

### A0. Establish the census, baselines, and oracles

**Purpose.** Separate identity, semantic dispatch, display, ABI, and ordinary
text uses before changing representation. Static grep alone overcounts and a
wall-clock sample alone cannot price allocation removal.

**Deliverables.** Add a read-only `scripts/compiler-identity-census` report
with stable machine-readable rows for:

- string fields on phase values (`ParsedIdentifier`, typed nodes, `CoreVar`,
  closure captures, call targets, type/member references);
- `Dict[String, ...]` and `Set[String]` grouped by owning phase and purpose;
- comparisons against literals or another `.name`;
- ID-to-name and name-to-ID conversions;
- constructors with `id = 0` or `def_id = None`;
- direct `c_local_name`, `c_identifier`, and symbol-concatenation call sites;
- diagnostic, dump, formatter, reflection, foreign, and exported-ABI allowlist
  sites;
- definition-ID frontier gaps from the graph through every Core producer;
- duplicate authored `ParsedIdentifier.span` values within a single body;
- resolved nodes that repeat a definition/display/owner record instead of a
  typed key into one authority;
- per-consumer indexes that rebuild the same relation, and hot rows carrying
  sparse `Option` facts that could be satellite tables.

Add debug-only counters for dynamic calls to `core_var_equal`, variable-name
string equality/hash, local-scope lookup, `CoreVar` construction, and ID-to-name
display lookup. Counters must be allocation-neutral when disabled.

**Correctness fixtures.** Retain small cases covering:

- nested shadowing, including match arms and lambdas;
- two modules defining the same spelling;
- overloaded callables sharing a spelling;
- closure capture under shadowing;
- function cloning/inlining with repeated local spellings;
- synthetic binders produced by match lowering, specialization, Perceus, and
  closure conversion;
- foreign/exported names, reserved C identifiers, reflection/type-name output;
- Core JSON round-trip and identical diagnostic text.

**Measurement.** Freeze one `origin/main` input and record `-O2` self-compile
allocations, retired instructions, and these rows: source discovery,
`typed_frontend_complete`, `core_lowering_complete`, each touched Core pass,
and backend/emission. Preserve the raw JSON and generated-C hashes in
`benchmarks/results/` when implementation begins.

**Exit criteria.** Every current string use in the targeted variable/callable
path has one classification and owner; the fixtures fail if identity is
mistaken for spelling; disabled instrumentation is byte-identical and
allocation-identical. C0a emits the initial machine-readable ratchet budgets,
and the non-increase check is usable immediately even though migrated budgets
do not become strict zero requirements until C11b.

### A1. Define the identity types and catalog ownership

**Purpose.** Establish one vocabulary before adding more integer fields.

**Change.** Introduce `DefinitionValueId`/`ResolvedValueId` constructors and
equality in a phase-neutral identity module. Reuse the existing `ModuleTable`,
`SourceNameTable`, and `DefinitionTable`; do not build replacement copies.
Define the generated-definition overlay and binding-display catalog, but
publish authored rows only once per body batch and generated rows only through
the shared minting API.

The logical Core identity state is explicit from the start:

```blorp
record CoreIdentityState {
	definitions: DefinitionTable,
	authored: AuthoredIdentityFacts,
	first_managed_definition_id: Int,
	next_definition_id: Int,
	next_local_ordinal_by_definition: List[Int],
	generated_definition_displays: List[GeneratedDefinitionDisplayFacts],
	synthetic_binding_displays: CoreBindingDisplayCatalog
}
```

The production type is opaque. `CoreIdentityBuildState` is its private,
uniquely owned stage-8 construction form; `finish_core_identity_build`
publishes the first `CoreIdentityState`. Later Core minting functions consume
and return that state through `CorePassState`.

`CompilerIdentityFacts` is the read-only projection of this state exposed to
diagnostics/emission, not a second stored authority.

The graph allocator is monotonic, so a row index is
`definition_id - first_managed_definition_id`. C0a adds an invariant that all
graph and later Core definition IDs form this contiguous range. A row for a
non-body definition stores zero and rejects local minting; an executable body
stores one past its highest local ordinal. If the invariant exposes a genuinely
sparse producer, stop and use an explicit dense definition-ID-to-row map; never
allocate a list up to a sparse maximum.

A1 defines the state and lookup rules, but does not yet put the managed value
on every recursive helper. A3 initializes the ordinal column from
`TypecheckedGraph.authored_identity_facts`. A4 makes `CorePassState.identity`
the sole owner, replaces
`next_def_id`, and updates every state-reconstruction adapter and early/late
handoff to carry the complete identity state.

Run two generated-C/allocation probes. First compare binding-display carriers
on both fresh and seeded-body materialization:

1. canonical per-body row records plus an outer owner-to-body-row index;
2. canonical per-body parallel columns plus the same outer index;
3. a flattened graph projection retained beside reusable body outcomes.

The third candidate must count the simultaneous lifetimes and is rejected if
it copies rows/strings or causes COW. Whichever per-body carrier wins remains
the canonical immutable artifact stored in each body outcome; graph assembly
does not independently rebuild its contents.

Then compare three physical layouts behind the one opaque
`CoreIdentityState` field:

1. frontiers and catalogs directly in the identity record;
2. a small frontier record plus one nested immutable catalog record;
3. flat parallel columns in the identity record, borrowed by display readers.

Choose the carrier with no per-pass allocation and no extra retain/release in
the hot pass update. `CorePassState` carries that single opaque value and every
minting operation returns its replacement. Record the generated-C evidence in
the implementation issue; do not guess.

**Tests.** Smart-constructor tests, rejection of type/field/trait definitions
as values or body owners, definition/local namespace distinction, contiguous
frontier validation, builtin-ID handling, table provenance mismatch,
deterministic row order, missing-row diagnostic, and same spelling/different
ID.

**Oracle.** Byte-identical generated C and diagnostics. No performance claim;
reject a carrier that regresses matched whole-compile instructions or
allocations by more than 0.5%.

### A2. Resolve authored local bindings once

**Purpose.** Stop asking later consumers to reproduce lexical resolution.

**Boundary.** Run a pure body resolver after graph definition IDs exist and
immediately before inference consumes a body. It assigns local ordinals in a
deterministic walk and publishes a use-site resolution table. The same landed
cut makes inference consume that table for the supported binder family and
deletes the corresponding name-based local lookup. Never land a complete,
unused second resolver.

The required product is the normalized `ResolvedBodyNames` schema in the C2a
handoff above: binding, use-site, and local-target tables are separate; hot
accessors use their derived indexes; and `InferBodyFacts` supplies the source
table/definition authority by borrow. Do not replace it with a dictionary from
location directly to a materialized symbol or display row.

The resolver assigns a dense body-local `ResolvedNameSiteId` in deterministic
source-walk order. `ParsedIdentifier.span` is the exact authored token extent
and becomes a column of the site table, not the semantic key. A derived
`site_by_location_raw` index is valid only because C0a asserts authored identifier
locations are unique within the body and excludes compiler-prelude/recovery
identifiers from publication. If a legal authored construct violates that
invariant, change the derived ingress index explicitly; do not disambiguate by
spelling, pointer identity, or an undocumented “first match.” The site ID
remains body-local, so any retained reference is paired with its body artifact
and cannot collide with an equal singleton-file `SourceLocation` elsewhere.

The resolver owns one unshared builder with `current_by_name` and an undo log:

```text
enter binder: save the previous value for its spelling, then set the new ID
resolve use:  one current_by_name lookup
exit scope:   replay the scope's undo entries in reverse
```

Until A11, `current_by_name` is the final string-keyed lexical boundary. Local
mutation keeps the dictionary unique; snapshots are forbidden. This gives one
expected-constant-time lookup and one push/pop per local occurrence, rather
than a scope-chain walk. Counters report lookups, updates, undo entries, and
unexpected COW copies. A non-local use continues to existing
definition/import resolution, which writes a definition-valued
`ResolvedValueId` after canonical selection.

**Scope limit.** C2a's resolver walk enumerates every lexical binder and assigns
every authored binder/use its final ID. Parameters and straight bindings switch
their inference reads in the same commit. Uses belonging to later binder
families are explicitly `LegacyConsumerLocalBodyNameUse`, with an exact local
target, until their consumer changes land. C2b switches lambda, block, and loop
consumers. C2c switches ordinary match patterns, question-bind, select,
concurrent, and with/resource consumers, then deletes the transitional variant
and legacy-local path. Each cut reduces the ratchet for its family and deletes
its old lexical lookup. Do not rewrite unrelated inference state.

**Tests.** One fixture per binder form; shadowing across every scope boundary;
same name in sibling arms; use-before-binding behavior; exact existing error
messages for unknown names; deterministic IDs on two identical runs.

**Fast loop.** A resolver-only fixture or body-check worker, then
`scripts/compiler-check --stage typecheck`. Use `--stop-after=lower` for the
first self-compile comparison.

**Oracle.** Typed output and lowered Core are byte-identical. Resolver work is
linear in parsed nodes in expected hash-table cost; the measured counters are
bounded by a constant multiple of identifier sites. The new table is built
once per body, inference is its active consumer, and no body node stores a new
`String`.

### A3. Propagate the thin ID spine through typed AST and lowering

**Purpose.** Make every binder and variable use reach Core with an exact ID
while retaining names temporarily as checked compatibility data.

Prepare A3 as three independently compiling, separately reviewable commits,
then land them as one atomic train at the C3c endpoint:

1. **C3a — transitional Core carrier.** Add the tagged inline identity field
   and transitional JSON schema in `ir.brp`. Mechanically update every existing
   `CoreVar` constructor in lowering, Core, backend helpers, and tests to use
   the pending constructor. The before/after constructor census must match;
   this cut makes no semantic consumer read identity.
2. **C3b — typed spine.** Add resolved identity to typed binder/use facts with
   no Core producer switch yet.
3. **C3c — lowering switch.** Install the orchestration-owned identity builder,
   make authored and definition-valued lowering constructors resolved, delete
   lowering's name-based local lookup, and leave only A4's enumerated synthetic
   constructors pending.

**Typed change (C3b).** Add the resolved identity to typed binder/use facts. Extend
`VarSymbol` with `ResolvedValueId` for locals; top-level bindings carry the
definition-valued form of the same type. `TypedNameExpr`, assignment targets, patterns, closure
parameters, and all binder-carrying typed records expose the resolved ID to
lowering.

**Core carrier (C3a).** A3 cannot require every existing Core producer to have
an ID yet, because A4 owns synthetic/cloned producers. Use an explicitly
tagged, inline transition instead of
`Option[ResolvedValueId]` (which may box a struct payload):

```blorp
enum TransitionalValueIdentityState:
	ResolvedTransitionalValueIdentity
	PendingSyntheticValueIdentity

struct TransitionalValueIdentity {
	state: TransitionalValueIdentityState,
	owner_definition_id_raw: Int,
	local_ordinal: Int
}

record CoreVar {
	name: String,
	id: Int,
	def_id: Option[Int],
	identity: TransitionalValueIdentity
}
```

Private smart constructors are the only way to create this struct. A resolved
constructor requires `DefinitionValueId` plus a valid ordinal and stores their
raw fixed-layout fields. A pending constructor initializes named private
placeholder constants. C3a updates every existing constructor to pending;
C3c switches authored/definition-valued sites, after which only legacy
synthetic constructors on the C4 producer census may call it. Consumers must match `state` before reading the scalar fields;
the compatibility `name`/`id`/`def_id` fields remain authoritative only for
not-yet-migrated consumers. This adds no wrapper allocation; C3a verifies the
inline generated-C layout.

**Lowering switch (C3c).** Every resolved construction asserts that `name` agrees with the
binding/definition display row. `CoreLowerScopeEntry { name, id }` and
`resolve_local_id` disappear when the last lowering consumer switches in C3c.
Source-offset-derived legacy binder IDs remain only as compatibility output
until A8; no semantic code added after C3c may consult them.

Before the first module is lowered, graph preparation initializes a uniquely
owned `CoreIdentityBuildState` from the frozen `DefinitionTable` and
`TypecheckedGraph.authored_identity_facts`: record the table's first ID/range,
borrow the already-published authored binding display catalog, and fill each
local-ordinal frontier from its canonical rows. Do not retain or rescan
body-local `ResolvedBodyNames`. Keep that builder at the
module/declaration orchestration loop; do **not** put the full managed state in
`CoreLowerContext`, which is passed through recursive expression lowering.

Remove `CoreLowerContext.next_def_id`. For each stage-8 declaration that lacks
a graph ID, the orchestration loop calls `mint_generated_definition` first and
passes the resulting `DefinitionValueId` into the lowering function. The
function returns its lowered declaration, not a hidden replacement identity
state. Entrypoint synthesis explicitly takes and returns the builder because it
creates a definition. C0a must confirm that recursive expression lowering does
not mint definitions; if a future expression form does, its result type must
explicitly return the updated builder and receive a dedicated generated-C/COW
probe before that path lands. Immutable definition/authored-display lookup
facts may be borrowed through `CoreLowerContext`.

The intended ownership boundary is visible in code: orchestration owns and
replaces the builder, while recursive lowering borrows frozen facts and returns
only the lowered value.

```blorp
-- Before: recursive context carries a definition counter and local name map;
-- helpers can accidentally become identity issuers.
pure func lower_declaration(
	context: CoreLowerContext,
	declaration: TypedDeclaration,
) -> CoreLowerDeclarationStep

-- After: the outer loop is the only mutating owner.
pure func lower_typed_program(
	typed: TypedProgram,
	authored: AuthoredIdentityFacts,
) -> CorePreparedGraph:
	var identity_builder = new_core_identity_build(authored, typed.definitions)
	var declarations: List[CoreDeclaration] = []
	for declaration in typed.declarations:
		prepared = prepare_declaration_identity(identity_builder, declaration)
		identity_builder = prepared.builder
		context = core_lower_context(prepared.definition_id, authored)
		declarations = declarations.append(lower_declaration(context, declaration))
	{
		program = core_program(declarations),
		identity = finish_core_identity_build(identity_builder),
	}
```

`prepare_declaration_identity` is the only code in this loop allowed to mint a
generated definition. `lower_declaration` may read IDs already present on typed
nodes; it cannot return or hide an identity-state replacement. If a future
expression form truly creates a definition, promote that fact to an explicit
orchestration operation instead of threading the builder through every
expression helper.

At the graph boundary, replace `CorePreparedGraph { program, next_def_id }`
with `{ program, identity }`. This is the point at which graph preparation
freezes the build state and stops dropping the definition table. The generated
overlay is complete from its first row and is never reconstructed by scanning
the lowered program. Standalone Core tests use a checked
fixture constructor that builds the same authority from their declared
definition IDs; they do not fabricate an empty catalog and rely on fallback
names.

**Important.** This cut should remove lowering's repeated local scope walk. It
must not add a second name-to-ID dictionary in lowering. The resolver table is
the authority.

**Tests.** Lowering tests cover every typed binder shape, unresolved/recovery
nodes, graph-backed and standalone lowering, and conflicting definition IDs.
The compatibility assertion gets a deliberate mismatch test. C3a adds a
constructor-census test that fails when any `CoreVar` initializer bypasses a
transition smart constructor; C3c pins the exact remaining pending count and
locations handed to the C4 producer cuts.

**Oracle.** C3a versions Core JSON with an explicit `identity_state`, so raw
parent/candidate Core JSON is intentionally not byte-identical. C3a adds a
tested `benchmarks/compare_core_identity_transition` tool. It projects the
candidate's legacy `CoreVar` fields, proves their paths/cardinality/content
match the parent dump, and separately validates every candidate identity tag,
pair, pending/resolved census, and candidate JSON round trip. It must reject a
missing/duplicated variable, changed legacy field, malformed identity, or any
non-identity structural change. Resolved
variables include `owner_definition_id` and `local_ordinal`; pending synthetic
variables include only the pending tag and retain the existing legacy fields.
The decoder reconstructs the same tagged state, so round trips do not silently
lose identity. C4c moves to the final required-identity schema once the pending
count is zero. Generated C and diagnostics remain byte-identical. Inspect
generated C around `CoreLowerContext`, `CoreVar`, and the declaration loop to
prove the tag/scalars are inline and ordinary recursive lowering acquired no
identity-state retains, record copies, COW updates, or per-variable wrapper
allocation. Measure `core_lowering_complete`, local scope lookup calls,
allocations, and instructions.

**Acceptance at the atomic C3c endpoint.** Zero string-keyed local resolution
in lowering; zero authored or definition-valued `CoreVar` in the pending state;
every remaining pending site appears in the exact synthetic-constructor census
assigned to the C4 producer cuts; no regression above 0.5%; retain any direct
reduction in lowering work.

### A4. Make synthetic and cloned binding identity complete

**Purpose.** Remove the `id = 0` escape hatch before semantic consumers trust
IDs exclusively.

**Change.** Make `CorePassState.identity: CoreIdentityState` the persistent
authority. A3 initializes `next_local_ordinal_by_definition` once from the
resolved authored bodies: each executable definition row contains one past its
greatest authored ordinal, non-body rows contain zero, and generated rows are
initialized from `GeneratedDefinitionKind`: an executable owner starts at one,
while a non-body runtime value starts at zero and rejects `mint_local_value`.
The state owns `next_definition_id`; remove the parallel
`CorePassState.next_def_id` field.

Every adapter that currently reconstructs `CorePassState` from
`(program, next_def_id)` is replaced by a constructor that takes the prior
state and preserves `identity` together with the node-ID allocator. The
early-to-late Core handoff carries this state rather than resetting it. No pass
rescans functions to recover a frontier. Require exactly these authority APIs:

```text
mint_generated_definition(state, provenance) -> (state, DefinitionValueId)
mint_local_value(state, owner, display_origin) -> (state, ResolvedValueId)
state_with_program(state, program) -> state
```

The first operation consumes the definition frontier and appends the generated
display and local-frontier rows atomically. The second validates an executable
owner, consumes that owner's ordinal, and appends the binding display row
atomically. Helpers may own and update the state locally while rewriting a
body, but must return the full state; a pass-local counter is never an
independent authority.

Classify constructors into three operations:

```text
preserve(var)                 same semantic binding, same ID
freshen_within(owner, var)    copied/new binding in same function, new ordinal
rehome(new_owner, var)        cloned/extracted function, new owner and ordinal map
```

Cloning is driven by binder introduction, not by rewriting every matching
name. Each clone operation owns `old ResolvedValueId -> new ResolvedValueId`
and, where call targets change, a separate old-definition -> new-definition
map. The required behavior is:

| Operation | Locally bound values | True free/global values | Capture ABI slots | Recursive definition reference |
| --- | --- | --- | --- | --- |
| structural rebuild | preserve | preserve | preserve | preserve |
| duplicate subtree in one owner | freshen each binder and its bound uses | preserve | n/a | preserve unless the pass explicitly retargets calls |
| inline callee into caller | freshen params/locals under caller and remap their uses | preserve | materialized arguments use caller identities | preserve/retarget only according to the inliner decision |
| clone/specialize function | rehome params/locals under new definition | preserve | preserve until closure conversion | retarget through the separate definition map when cloning recursion |
| extract/lift closure | rehome binders owned by the extracted body | preserve until captured | mint one fresh parameter per capture, then rewrite captured uses to that slot | preserve or retarget by the extraction policy |

Two clones of the same source function therefore share neither definition nor
local identities. A capture slot is distinct from the source value it carries.
Encountering a binder mints and records the mapping; encountering a use consults
that map and otherwise preserves the free identity. Never infer binding from
spelling.

Use match lowering as the first integrated producer pilot. Once C4a's
mint/preserve/remap API is frozen, standard inlining/SSA/tail recursion,
specialization/synthesis, Perceus, and closure conversion have no semantic
dependency on one another and may be developed in parallel with disjoint file
ownership. Rebase, measure, and merge them one family at a time in that risk
order. A pass may not fabricate uniqueness in a name such as
`"__tmp_" + counter.to_string()`.

Each producer cut replaces its pending constructor with `mint_local_value` or
the appropriate preserve/remap operation. When the pending census reaches
zero, replace `TransitionalValueIdentity` with required `ResolvedValueId` on
`CoreVar`; keep `name`/`id`/`def_id` only for the A7 compatibility consumers.
At that same zero-pending gate, version Core JSON from the transitional tagged
form to the final required numeric pair. No later stage may construct or decode
a pending identity.

Upgrade the current report-only identity check to validate exact
`ResolvedValueId`s and lexical binder/use consistency. Enable strict mode in the
owning tests first, then make strict validation the default once the frozen
self-compile reports zero violations after every pass.

**Tests.** Per-pass clone/freshen cases, two clones of one function, repeated
synthetic construction in one owner, closure extraction, same local ordinal
under two different owners, free-variable preservation, capture-slot
distinction, recursive clone retargeting, and missing display row. Add one
pipeline test in which two separate passes mint binders in the same original
function; the second pass must receive a higher ordinal without a rescan. Add a
second test where the first pass creates a definition and the later pass adds a
binder to it, proving that both overlay rows survived the handoff.

**Oracle.** Generated C remains byte-identical while names still drive output.
Strict invariant and pending-identity counts are zero. Synthetic-name
construction counters decline only when the old generated strings are
actually removed.

### A5. Derive emitted value symbols from identity

**Purpose.** Establish the backend beachhead from which strings can be removed
right-to-left.

Before touching emission, extend
`benchmarks/normalize_generated_c_symbols` to canonicalize the complete old
and proposed local-identifier families, including `brp_v<owner>_<ordinal>`.
Retain paired fixtures where old and new spellings normalize identically and
where a collision, missing occurrence, declaration/reference mismatch, or
structural C change does not. The tool must prove a one-to-one renaming; a
broad regex that hides arbitrary identifiers is not an oracle.

Callable projection already uses definition IDs. Extend the same rule to
globals and locals:

```text
callable definition          brp_f<definition-id>
global value                 brp_g<definition-id>
local binding                brp_v<owner-definition-id>_<local-ordinal>
```

Named C types, fields, and layout members remain A10 work even when their IDs
already exist; A5 must not absorb that separate ABI/layout surface.

Model symbol policy as two normalized domains. A builtin is not a fabricated
`ResolvedValueId`, and ordinary rows do not carry source spelling merely to
render a C identifier:

```text
ValueSymbol(value_id PK/FK, policy, rendered_symbol)
BuiltinSymbol(builtin_value_id PK/FK, policy, rendered_symbol)
```

```blorp
enum EmittedValueSymbolPolicy:
	DerivedValueSymbol
	ForeignValueSymbol
	ExportedValueSymbol
	PlatformEntrypointSymbol

record ValueSymbolTable {
	value_ids: List[ResolvedValueId]
	policies: List[EmittedValueSymbolPolicy]
	rendered_symbols: List[String]
	row_by_value_id: ResolvedValueRowIndex -- private derived index
}

enum BuiltinSymbolPolicy:
	RuntimeBuiltinSymbol
	IntrinsicBuiltinSymbol
	PlatformBuiltinSymbol

record BuiltinSymbolTable {
	builtin_value_ids: List[BuiltinValueId]
	policies: List[BuiltinSymbolPolicy]
	rendered_symbols: List[String]
}

-- The renderer performs projection only; it does not decide policy.
pure func emit_value_reference(
	symbols: ValueSymbolTable,
	value_id: ResolvedValueId,
) -> String:
	value_symbol(symbols, value_id)
```

If the measured direct-rendering carrier wins, `rendered_symbols` may be a
computed projection rather than a stored column. The logical policy table and
the separation of value/builtin keys remain unchanged.

Names are examples, not a frozen ABI. Split the implementation into two cuts:

1. build an ID-keyed emission table that deliberately reproduces today's C
   spellings, switch all declarations/references to it, and delete direct
   renderer name projection; raw C must remain byte-identical;
2. change ordinary table rows to ID-derived symbols, after the normalizer test
   is green; normalized C and runtime behavior become the oracle.

Use the existing base-62 encoder and program-wide reserved-symbol plan. The
symbol-policy decision is made once per ID. Before choosing storage, compare a
dense ID-indexed symbol column with direct rendering from the fixed-layout ID;
retain the table only if avoiding repeated formatting repays its strings and
capacity. Do not add a dictionary or repeat source-name sanitization at every
occurrence.

Keep explicit exceptions:

- `foreign` C names;
- source-declared exported ABI symbols;
- runtime-mandated builtin symbols;
- `main` and other platform entry points;
- language reflection whose specified result is a source name.

Those exceptions are represented by a backend symbol policy variant, not by
testing source spelling inside the renderer.

**Tests.** Same-spelled locals, reserved C words, compiler-generated prefixes,
two modules with the same declaration name, all ABI exceptions, split-C
emission, and symbol-map/profile rendering.

**Oracle.** The first cut is raw-byte-identical. The second intentionally
changes C identifiers, so compare the retained parent/candidate C with the
tested one-to-one normalizer plus runtime behavior, compiler fixtures, leak,
sanitizer, and codegen audit. Keep diagnostics and reflection output exact.
Both performance comparisons use parent and candidate stage-2 compilers.

**Acceptance.** No ordinary callable/global/local output symbol depends on a
source string. Symbol policy is one build per program, all access is by ID,
the chosen render/cache representation has better or flat measured
instructions and allocations than the alternative, and the backend pass row
does not regress.

### A6. Remove semantic string decisions from the backend

**Purpose.** Prevent the renderer from becoming a hidden name-resolution
layer after output symbols move to IDs.

Classify every backend `.name`, string literal comparison, and name-keyed
dictionary. A6 converts value/callable decisions whose exact definition IDs
already exist. Named-type and member families are classified and explicitly
deferred to A10 rather than widened into this cut:

| Class | Action |
| --- | --- |
| identity | replace with `DefinitionId`, `ResolvedValueId`, `TypeId`, or member ID |
| intrinsic/runtime policy | resolve upstream into an explicit call/policy variant |
| display/diagnostic | use the display table at the rendering boundary |
| foreign/exported ABI | retain an explicit ABI spelling fact |
| template-local C temporary | leave as renderer-owned text |
| user data | leave unchanged |

Example:

```blorp
-- Wrong boundary.
if call.name == "some_runtime_intrinsic":
	emit_intrinsic(call)

-- Upstream decision, backend rendering.
match call.target:
	IntrinsicTarget(SomeRuntimeIntrinsic): emit_intrinsic(call)
	_:	...
```

Do this one decision family per commit. The cut introducing a resolved variant
deletes the old spelling predicate and fallback in the same change.

**Oracle.** Byte-identical or normalized-identical C according to whether the
rendered spelling changes; exact runtime/diagnostic behavior. The census has
no unclassified backend semantic name read.

### A7. Convert late-Core consumers to exact IDs

**Purpose.** Remove operational dependence on compatibility
`CoreVar.name`/`id`/`def_id` while those fields still exist for unmigrated
consumers and display.

Land final preparation/cancellation/backend projection first because it owns
the shared projection seam. After that seam is frozen, the remaining consumer
families have no semantic dependency on one another and may be developed in
parallel when their file ownership is disjoint. Keep one family per cut, then
rebase, measure, and merge one cut at a time in this recommended risk order:

1. final preparation, cancellation plans, and backend projection;
2. closure capture/free-variable sets;
3. Perceus ownership-use, borrowed-owner, mutable, and repeated-consume
   catalogs;
4. reuse/field-take alias catalogs;
5. DCE value and reachability indexes;
6. match projection/lowering and tail-recursion helpers;
7. specialization, synthesis, mono, and earlier Core rewrites.

For each family:

- replace private equality with `ResolvedValueId` equality;
- replace name-keyed exact-variable collections with ID-keyed collections;
- retain name-keyed declaration overload groups only until their exact
  definition selection moves upstream;
- remove unresolved-identity/name-only fallbacks;
- leave unsupported-expression fallbacks intact and count them separately;
- add a shadowing test that would give the wrong answer under name equality.

For closure capture, publish the result as an edge table rather than copying
the captured variable record into each consumer:

```text
ClosureCapture(
  closure_definition_id FK,
  capture_slot,
  captured_value_id FK,
  PK (closure_definition_id, capture_slot),
  UNIQUE (closure_definition_id, captured_value_id)
)
```

```blorp
record ClosureCaptureTable {
	closure_definition_ids: List[DefinitionValueId]
	capture_slots: List[Int]
	captured_value_ids: List[ResolvedValueId]
	first_capture_row_by_closure_raw: Dict[Int, Int] -- derived range index
	capture_count_by_closure_raw: Dict[Int, Int]     -- derived range index
}

-- Slots are dense and ABI-significant within one closure. The display name is
-- joined only when a diagnostic or dump asks for it.
pure func capture_value_id(
	captures: ClosureCaptureTable,
	closure: DefinitionValueId,
	slot: Int,
) -> ResolvedValueId
```

Perceus, DCE, and reuse tables follow the same pattern: their rows key the
narrow decision fact by `ResolvedValueId` or by an explicit edge key. They do
not own a second variable catalog. If two consumers need the same relation,
publish it once at the pass that owns the decision instead of rebuilding a
name index in both consumers.

Dictionary-to-dense-list conversion is a separate measured choice. Integer
keys remove hashing/string equality, but dictionary probes do not allocate.
Use a dense list only when IDs are compact in that consumer and the required
capacity does not dominate. Otherwise use the exact typed-ID key if the
standard dictionary supports it, or a two-level owner-ID/local-ordinal table;
do not flatten the pair into a magic integer.

**Oracle.** Byte-identical C. A changed answer should be retained only when a
test proves the old name-based result was incorrect. Report phase rows and
string hash/equality counters; do not promise allocation savings from key
replacement alone.

### A8. Delete strings from Core value identity

**Start gate.** The C7 consumer cuts are complete, strict identity is green,
emission is ID-derived, and C7d's final census finds no semantic
`CoreVar.name`, `.id`, or `.def_id` read.

**Change.** Replace compatibility
`CoreVar { name, id, def_id, identity: ResolvedValueId }` with the fixed-layout
`ResolvedValueId` (or its zero-cost opaque representation). Closure captures,
parameters, loop binders, pattern binders, cancellation plans, and ownership
facts store the same scalar identity. Remove `CoreVar.name`, `CoreVar.id`,
`CoreVar.def_id`, and the compatibility wrapper together with all compatibility
constructors.

Diagnostics, Core JSON, dumps, and optional symbol-map readability resolve
through `CompilerIdentityFacts`. Serialization should include the numeric ID
and rendered display name where useful, but decoding may not use the display
name to establish identity. A8 preserves the identity-based JSON schema
installed by C4c's zero-pending gate; deleting the in-memory compatibility
record is not another wire-format change.

This is the first cut expected to remove the broad ARC/record cost: variable
occurrences no longer retain a heap record containing a `String`. Inspect the
generated C to prove that passing/comparing a `ResolvedValueId` is scalar/fixed
layout and introduces no allocation.

**Tests.** Core JSON round trip, all diagnostics that mention variables,
profile/symbol maps, display-row loss, shadowing, and the complete Core suite.

**Oracle.** Normalized C plus compiler/runtime/leak/sanitizer gates; exact
diagnostic text. Primary evidence is whole-self-compile allocations, retired
instructions, ARC samples, and the touched Core pass rows.

**Acceptance.** Zero `String` field in Core variable identity; zero Core
semantic name fallback; no more than one display lookup per rendered item;
positive allocation or instruction evidence, or stop and investigate why the
fixed representation did not remove the expected managed traffic.

### A9. Move the frontier through typed frontend values

**Purpose.** Prevent typechecking and lowering from retaining a source spelling
on every resolved identifier occurrence.

Keep the parser/formatter recovery AST unchanged initially. Publish successful
typed resolution in normalized side tables rather than attaching another
record to each syntax node. The logical relation is one target table, but its
physical storage is two disjoint satellites because local and non-local rows
become known at different times:

```text
ResolvedNameSite(owner_definition_id FK, resolved_name_site_id,
                 location,
                 PK (owner_definition_id, resolved_name_site_id))
LocalNameUseTarget(owner_definition_id, resolved_name_site_id,
                   value_id FK,
                   PK/FK (owner_definition_id, resolved_name_site_id))
NonLocalNameUseTarget(owner_definition_id, resolved_name_site_id,
                      value_id FK,
                      PK/FK (owner_definition_id, resolved_name_site_id))

ResolvedIdentifierTarget = LocalNameUseTarget UNION ALL NonLocalNameUseTarget
```

```blorp
record NonLocalNameUseTargetTable {
	name_site_ids: List[ResolvedNameSiteId]
	value_ids: List[ResolvedValueId]
	target_row_by_name_site_raw: Dict[Int, Int] -- derived sparse lookup
}

-- C9 atomically renames C2's four-field ResolvedBodyNames to this type.
-- Its layout and rows do not change; inference only reads it.
record ResolvedBodyNameInputs {
	owner_definition_id: DefinitionValueId
	bindings: AuthoredBindingDisplayTable
	name_uses: BodyNameUseTable
	local_targets: LocalNameUseTargetTable
}

-- This is the only artifact stored after C9 inference completes. Keeping the
-- input product nested avoids flattening or copying its column lists.
record ResolvedBodyNames {
	inputs: ResolvedBodyNameInputs
	non_local_targets: NonLocalNameUseTargetTable
}
```

Both physical target satellites are sparse: unresolved/recovery sites remain
in the site table and diagnostics, but they do not receive an invalid or
sentinel value ID. A typed success must occur in exactly one satellite. The
public `resolved_identifier_target` accessor checks the site's migration/use
kind and reads the corresponding satellite; consumers may not probe both or
observe the split. Measure this carrier against a dense, explicitly tagged
success/failure slot if lookup density makes it a candidate; never encode
failure as a magic integer.

`ResolvedNameSiteRef(owner_definition_id, site_id)` is the logical composite
key, not a struct payload to store in `TypedExpr`. C9's representation probe
must compare two scalar union fields with two scalar fields in the already
allocated `TypedExprInfo`/owning typed record. A standalone struct inside the
erased typed-expression union is rejected if generated C uses
`blorp_box_struct` or the allocation census rises per name occurrence. The
typed accessor accepts/returns the two typed scalar components without putting
the composite in `Option`, a list element, or another erased payload.

C9 must not append into C2's borrowed `local_targets`. Inference owns a
separate, initially empty `NonLocalNameUseTargetBuilder`; immutable body facts
remain in `InferBodyFacts`, while the accumulator is a distinct field of the
owned per-body inference session. `BodyInferSessionSeed` contains neither the
builder nor facts from a previous body.

```blorp
private record InferBodyBuildState {
	non_local_targets: NonLocalNameUseTargetBuilder
}

-- Literate shape: the real InferSession keeps its existing fields as well.
record InferBodyFacts {
	definition_authority: BodyDefinitionAuthority
	resolved_name_inputs: ResolvedBodyNameInputs
}

record InferSession {
	-- borrowed facts; never updated by inference
	body_facts: InferBodyFacts
	-- uniquely owned accumulator; never published directly
	body_build: InferBodyBuildState
}

private pure func infer_non_local_name_expr(
	context: InferContext,
	name: ParsedIdentifier,
) -> InferResult:
	-- Existing declaration/import resolution produces this exact ID.
	resolved = resolve_non_local_value(context, name)
	site_id = body_name_site(
		context.state.body_facts.resolved_name_inputs,
		name.span,
	)
	build = append_non_local_name_use_target(
		context.state.body_build,
		site_id,
		resolved.value_id,
	)
	infer_resolved_non_local_name(context.with_body_build(build), name, resolved)
```

The append helper consumes and returns the unique builder. It does not accept
`ResolvedBodyNames`, `LocalNameUseTargetTable`, or a shared session seed. At
the body outcome boundary, finalization consumes the builder once, freezes the
non-local satellite, and constructs the C9 `ResolvedBodyNames` from the four
unchanged C2 fields plus that satellite:

```blorp
private pure func finish_resolved_body_names_after_inference(
	inputs: ResolvedBodyNameInputs,
	body_build: InferBodyBuildState,
) -> ResolvedBodyNames:
	{
		inputs = inputs,
		non_local_targets = finish_non_local_name_use_targets(
			body_build.non_local_targets,
		),
	}
```

This function is the only C9 construction boundary. The fresh path moves the
same `ResolvedBodyNameInputs` value returned with the inference session into
the final artifact; it does not reconstruct its four tables. Accepted and
recovered function outcomes and completed annotated/inferred global headers
store the resulting `ResolvedBodyNames`. Seeded function and global reuse
borrow that finalized artifact unchanged and do not rerun the resolver or
inference. Consumers of finalized facts read local rows through
`names.inputs.local_targets`; pre-inference consumers accept
`ResolvedBodyNameInputs` and therefore cannot accidentally request a
non-local result before it exists.

The C9 measurement must show that the input product's rows, order, and content
hash are unchanged, that no local-table COW copy occurs, and that non-local
builder appends equal the published non-local row count. Inspect generated C
to verify that nesting the inputs transfers one existing reference rather than
copying its columns or boxing rows. If constructing the final outer record
causes surprising per-row retains or copies, stop at the representation probe
rather than denormalizing the logical schema.

Binder display facts retain the source spelling once. Typed name expressions,
assignment targets, pattern uses, and closure captures retain that logical
owner/site key using the measured scalar carrier (or directly the value ID when
the node has no diagnostic need); they
stop carrying `ParsedIdentifier`. Typechecking scope dictionaries may still
use existing `SourceNameId` keys for module-visible declaration indexes, but
the body lexical environment remains `String`-keyed through C9. Inference
after either lookup uses the resulting binding/definition ID. This is the same authored
name-site authority introduced by A2 and retained per body in both reusable
outcomes and `TypecheckedGraph.authored_identity_facts`. C9 adds the disjoint
non-local satellite, switches every resolved-use consumer to the one logical
accessor, and deletes any ad hoc non-local target or span cache in the same
cut. The site table and existing local rows keep their IDs and order. The
enclosing body row supplies `owner_definition_id`; detached typed nodes carry
the measured scalar representation of the logical
`ResolvedNameSiteRef(owner_definition_id, site_id)`, so body-local integers
never collide. No overlapping target table or competing span table survives
the cut.

Then narrow the resolved side of the body environment itself:

- unresolved lookup key remains the current `String` boundary until A11;
- symbol row identity: `ResolvedValueId`;
- resolved-use table: ID only;
- diagnostics: ID -> display facts;
- no later scope-chain walk by source name.

A9 must not mint local `SourceNameId` values or extend the current
declaration-only `SourceNameTable`; doing so would create a second spelling
authority before A11. A11 converts the remaining unresolved environment key
only after it defines the parser/local-spelling projection.

Do not combine this with an environment ownership/builder rewrite. Measure
string hashing/equality and scope lookup separately from state-copy behavior.

**Oracle.** Exact typed diagnostics and byte-identical lowered Core/C. The
formatter remains the parser-spelling oracle. Typecheck and lowering phase
allocations/instructions and dynamic scope lookup counts are primary.

### A10. Extend the rule to nominal types and members

Variables are the pilot. Freeze the common type/member identity and display
schema, then apply the same pattern one identity family per cut. The numbered
order is the recommended integration/risk order, not a semantic dependency;
disjoint family cuts may be developed in parallel, then rebased, measured, and
merged one at a time:

1. named types (`TypeId`);
2. constructors/variants (`DefinitionId`/`ConstructorId`);
3. record/union fields (`FieldId`);
4. traits and trait methods (`TraitId`/callable definition ID);
5. globals and module-qualified imports already not covered by A7;
6. intrinsic/runtime operations as explicit enums.

Use separate module-local site-ID namespaces for type and member occurrences;
an integer row from one family must not be accepted by the other. The logical
schema is:

```text
TypeNameSite(module_id FK, type_name_site_id, location,
             PK (module_id, type_name_site_id))
ResolvedTypeTarget(module_id, type_name_site_id, type_id FK,
                   PK/FK (module_id, type_name_site_id))

MemberNameSite(module_id FK, member_name_site_id, location,
               PK (module_id, member_name_site_id))
ResolvedFieldTarget(module_id, member_name_site_id, field_id FK,
                    PK/FK (module_id, member_name_site_id))
ResolvedCallableTarget(module_id, member_name_site_id, definition_id FK,
                       PK/FK (module_id, member_name_site_id))
```

Only one target satellite is legal for a successful member site; use an
explicit target-family tag if a single member-resolution table is physically
preferable. `FieldId` already joins the canonical `DefinitionTable` row, whose
`name` remains the display authority through A10. Do not add a parallel field
display column. A11 changes that canonical display column to `SourceNameId`
when the spelling authority moves.

```blorp
-- Hot semantic selection reads only the target table.
pure func resolved_field_id(
	module_id: ModuleId,
	site_id: ResolvedMemberNameSiteId,
	targets: ResolvedFieldTargetTable,
) -> FieldId

-- Diagnostics make the cold join explicitly.
pure func field_diagnostic_name(
	field_id: FieldId,
	definitions: DefinitionTable,
	source_names: SourceNameTable,
) -> String
```

For each family, the issue must name:

- the authoritative issuer and display table;
- the first phase at which a reference is resolved;
- every downstream representation that duplicates the string;
- ABI/reflection exceptions;
- the exact string-keyed indexes being deleted;
- the identity and performance oracle.

Coordinate named-type representation with `TYPE_INTERNING_ROADMAP.md`; do not
simultaneously change type interning, type equality, and emitted C naming.
Field and constructor display names may remain in layout metadata for foreign
ABI or reflection, but semantic selection is always by ID.

**Tests and acceptance.** For each family, cover same-spelled entities in two
modules/owners, qualification, imports, generic specialization, diagnostics,
reflection, and foreign ABI where applicable. The cut is complete only when
the census shows no semantic spelling lookup for that family after its
resolution point, generated C is raw- or normalized-identical as declared,
diagnostic/reflection text is exact, and its phase plus whole-compile
allocations/instructions are flat or better.

### A11. Consolidate source spelling IDs and enforce the boundary

Only after the downstream frontier is ID-only, remove redundant source-name
interning. The lexer already interns token text per file, while Stage 6 builds
a compilation graph `SourceNameTable`. Choose one explicit projection:

- parser identifiers carry a file-local text ID and discovery maps the names
  that cross the graph boundary to `SourceNameId`; or
- the finalized source AST directly carries a graph-issued `SourceNameId`.

Whichever projection wins must cover local binder/use spellings as well as
module-visible declarations before the body environment changes its unresolved
lookup key from `String` to `SourceNameId`. That environment conversion and
deletion of the last local-string key path land in C11a with the new spelling
authority; it is not pre-work in C9.

Do not make the recovery parser or formatter depend on a typecheck graph. The
formatter must continue to operate on source text and recovery AST alone.

After consolidation, promote C0a's existing ratchet from non-increase budgets
to strict hygiene checks for every migrated family:

- reject `Dict[String, ...]` for semantic entities in migrated directories;
- reject direct `.name` semantic comparisons in Core/backend;
- reject calls to display-name accessors outside allowlisted diagnostics,
  dumps, reflection, symbol maps, and ABI projection;
- reject new binder constructors that do not receive/mint identity;
- reject backend predicates that recognize semantics from a source spelling.

The check prints exact file/line violations and has a narrow allowlist owned by
the relevant boundary. Do not enforce it with a broad grep that flags ordinary
rendering strings.

**Tests and acceptance.** Run the formatter corpus without a typecheck graph,
all parser/typecheck diagnostic fixtures, and LSP definition, references,
rename, and highlight tests across incremental reparses. The source-name
census must show one documented projection between lexer/file-local text and
the graph `SourceNameId`; the previous duplicate interning builder is deleted.
Hygiene tests include one rejected violation and one accepted example for each
allowlist class. Generated C remains byte-identical, and parser/discovery/
typed-frontend allocations and instructions are flat or better.

## Logical dependency graph

The graph constrains authority switches. The integration waves above control
the practical branch and merge schedule.

```text
tooling: C0a/C0b/C5a --------------------------------------------+
                                                                  |
C1a -> C1b frontend probe -> C2a -> C2b -> C2c                    |
                                  -> [C3a -> C3b -> C3c] -> C4a   |
                                                      |           |
                          +---------------------------+-----------+
                          v
           C4 producer families -> strict identity
                          |
                          C5b
                    +-----+-----------------------+
                    |                             |
                    +-> C5c -> C6x ---------------+
                    |                             |
                    +-> C7a +-> C7b --------------+
                            +-> C7c --------------+-> C8
                            +-> C7d --------------+
                                                   |
                                                   v
                         C9 -> C10x -> C11a -> C11b strict
```

- C0a, C0b, and C5a are independent tooling/test cuts and should land early.
- C1a freezes the checked identity vocabulary before consumer workers branch,
  but merges only as part of the C1a/C2a train. C1b is a hard probe gate, not a
  standalone production landing: select its frontend carrier before C2a edits
  Env/catalog storage, land that carrier with C2a, and land its separately
  measured Core half with C3c.
- C2a/C2b/C2c may be investigated in parallel by binder family, but they share
  the frontend resolver/environment authority and normally integrate in order.
- C3a/C3b/C3c are one short train. Do not interleave unrelated compiler
  changes or leave the transition carrier dormant on main.
- C4a lands before synthetic-producer workers branch. The later C4 families
  are the first broad parallel implementation wave because they consume a
  frozen mint/remap API and own disjoint producer files.
- After strict identity, C5b freezes the shared symbol-plan seam. The C5c/C6x
  backend lane may then proceed while C7a lands the shared Core projection
  seam; only after C7a may C7b/C7c/C7d proceed in parallel. Shared projection
  or catalog APIs still have one owner, and overlapping backend edits merge
  serially.
- C8 is a one-owner Core representation flag day and waits for every semantic
  legacy-field read to reach zero. Other workers may prepare fixtures and
  censuses, but may not edit `CoreVar` concurrently.
- C9 follows C8. C10 family work can parallelize only after its common schema
  lands, with one source owner per type/member family.
- C11a changes the spelling authority once; C11b then flips the already landed
  ratchet budgets to zero. It does not introduce a new checker at the end.

Every implementation issue should fit one row or one consumer family above.
If a task needs to change two identity issuers or two phase boundaries, split
it before implementation.

### Implementation issue breakdown

Create these as separate reviewable changes. Cut numbers describe logical
architecture; the D0-D7 table defines practical merge order. A row may be
split further after its census, but adjacent rows should not be combined
merely to save gate time. C1a and C3a/C3b are the exceptions to independent
landing: retain them as reviewable commits, but apply the landing criteria and
ratchet only at the C2a and C3c endpoints of their atomic trains.

| Cut | Primary source boundary | Required result before landing |
| --- | --- | --- |
| C0a | new `scripts/compiler-identity-census`, Core/backend allowlist | stable text/JSON census and baseline ratchet budgets with zero production behavior change |
| C0b | debug counters near `core_var_equal`, scope lookup, construction, display reads | disabled build is byte/allocation-identical; retained baseline artifacts |
| C1a | `stage_06_typecheck/graph/definition_index.brp` plus new `stage_06_typecheck/graph/resolved_value_identity.brp` | phase-neutral checked `DefinitionValueId`/`ResolvedValueId`; illegal row-kind tests |
| C1b | representation probes for stage-6 authored facts/Env projection and stage-9 identity catalogs | frontend carrier selected before C2a production edits; no upstream Core import; physical layouts backed by generated C, fresh/seeded allocation counts, and surprising-COW stop rule; production frontend/Core halves land with C2a and C3c respectively |
| C2a | body resolver, `source.brp` scalar location-key projection, `decl.brp` accepted/recovered function artifacts plus completed-global artifacts/reuse, and `type_system/env.brp`/`infer.brp` parameter and straight-let paths | inference actively consumes IDs; fresh/seeded function and global paths publish identical canonical body facts in definition order; exact bind/refine/pop undo tests pass; no struct-key hashing is introduced; replaced name lookup deleted |
| C2b | lambda, block, and loop binder environment/inference consumers | their preassigned IDs become active; mixed shadowing is exact; each family's `legacy_local_name_use_sites` row reaches zero; resolver cardinality/order is unchanged |
| C2c | match, question-bind, select, concurrent, and resource binder consumers | all remaining preassigned IDs become active; the legacy-local ratchet reaches zero; the transitional variant/path is deleted; existing diagnostics remain exact |
| C3a | `stage_09_core/ir.brp`, every current `CoreVar` constructor from the C0a census, Core JSON tests, and `benchmarks/compare_core_identity_transition` | tagged inline transition compiles; all constructors pending; tested parent/candidate projection and transitional JSON round-trip pass; no consumer switch |
| C3b | typed binder/use records in `stage_06_typecheck/` | every successful local inference result exposes `ResolvedValueId` |
| C3c | `stage_08_core_lower/lower.brp` and `graph_prepare.brp` | orchestration-owned builder; authored/definition sites resolved; recursive context remains a reader; lowering scope lookup deleted; only enumerated C4 producer sites pending |
| C4a | `stage_09_core/pass_runner.brp`, pipeline handoffs, identity module | one persistent frontier; two-pass mint test green |
| C4b | match lowering and simple same-owner synthetic binders | zero raw `id = 0` in migrated families; strict invariant green there |
| C4c | cloning/inlining/specialization/closure producers | binder-driven remap matrix covered; pending count zero; required identity and final JSON schema installed |
| C5a | `benchmarks/normalize_generated_c_symbols` and its tests | old/new local schemes normalize one-to-one; structural changes survive |
| C5b | `stage_10_backend/c_symbol_projection.brp`, `emit.brp`, `c_naming.brp` | ID-keyed plan reproduces raw C; old renderer projection deleted |
| C5c | same backend boundary | ID-derived ordinary symbols; normalized C and stage-2 gates green |
| C6x | one backend value-policy family per cut | explicit resolved variant replaces and deletes one spelling predicate family |
| C7a | final preparation/cancellation/backend projection | exact-ID catalogs and byte-identical C |
| C7b | closure capture/free-variable analysis | shadow-safe exact captures; no name fallback |
| C7c | Perceus/reuse/DCE families, separately measured | exact-ID keys, collision fixtures, owning pass row flat or better |
| C7d | match/tail/specialization/mono remaining consumers | no semantic `CoreVar.name` read in census |
| C8 | `stage_09_core/ir.brp` plus all Core constructors/serialization | transitional `CoreVar` deleted; fixed-layout generated C proven |
| C9 | typed AST/environment, lowering compatibility fields, non-local-target builder/finalization, and logical owner/site carrier probe | resolved occurrences no longer retain `ParsedIdentifier`; local rows are unchanged and never COW-copied; fresh/seeded function and global artifacts publish identical finalized targets; no per-occurrence struct box/allocation; exact diagnostics |
| C10x | one nominal type/member family per cut | exact typed ID after resolution; named indexes deleted for that family |
| C11a | lexer/parser/source-finalization and `SourceNameTable` | one spelling projection; formatter and diagnostics exact |
| C11b | identity census ratchet and allowlist | all migrated budgets flipped to zero; new semantic strings/name comparisons rejected at exact file/line |

Each issue records base revision, frozen input, source/binary provenance,
narrow command, raw artifacts, identity oracle, phase rows, and an explicit
accept/reject recommendation. C4c, C6x, C7c/C7d, and C10x are families of
issues, not invitations for one cross-compiler patch. Attach the required
worker handoff, including the normalized logical schema and literate
before/builder/consumer/deletion sequence; a cut row alone is not an
implementation specification.

## Measurement protocol

Freeze the input and record provenance once per series. Measure the parent in
an untouched worktree before measuring the candidate; two labels applied to
the same currently built compiler are not a comparison:

```bash
base=$(git rev-parse origin/main)
id_cut=c3c-typed-core-spine
series_root=$(mktemp -d /tmp/blorp-id-migration.XXXXXX)
parent_tree="$series_root/parent"
git worktree add --detach "$parent_tree" "$base"
input=$(benchmarks/self_compile_measure freeze --rev "$base")

# Untouched parent compiler. Keep its generated C.
(cd "$parent_tree" && BLORP_CLI_C_OPTIMIZATION=-O2 make)
(cd "$parent_tree" && BLORP_CLI_C_OPTIMIZATION=-O2 \
  benchmarks/self_compile_measure --stage2 \
    --label id-migration-parent \
    --input-dir "$input" \
    --samples 3 \
    --keep-output "$series_root/parent.c" \
    --output "$series_root/parent.json")

# Candidate compiler, rebuilt after the edit. Keep its generated C too.
BLORP_CLI_C_OPTIMIZATION=-O2 make
scripts/compiler-build-status                    # must report FRESH
BLORP_CLI_C_OPTIMIZATION=-O2 benchmarks/self_compile_measure --stage2 \
  --label "id-migration-$id_cut" \
  --input-dir "$input" \
  --samples 3 \
  --baseline "$series_root/parent.json" \
  --keep-output "$series_root/candidate.c" \
  --output "$series_root/candidate.json" \
  --require-identical
```

This uses stage 2 for both sides, which is mandatory for C5c, C6x, C8, or any
change whose benefit depends on generated-C/runtime representation. A
frontend-only C2x/C3x/C9 cut may omit `--stage2` on both sides for the quicker
acceptance measurement, but must not compare stage 1 with stage 2.

For the C2x/C3x/C9 iteration loop, create the parent dump once, then recreate
the candidate dump after each rebuild:

```bash
(cd "$parent_tree" && bin/blorp compile --stop-after=lower \
  --dump-core-after=lower --dump-core-file="$series_root/parent.core" \
  --no-format --std-dir "$input/standard_library/src" -o /dev/null \
  "$input/blorp/src/main.brp")

bin/blorp compile --stop-after=lower --dump-core-after=lower \
  --dump-core-file="$series_root/candidate.core" --no-format \
  --std-dir "$input/standard_library/src" -o /dev/null \
  "$input/blorp/src/main.brp"

# C2x and C9 preserve the current Core JSON schema.
cmp "$series_root/parent.core" "$series_root/candidate.core"

# C3a-C3c intentionally add/version identity_state; do not use cmp.
benchmarks/compare_core_identity_transition \
  --parent "$series_root/parent.core" \
  --candidate "$series_root/candidate.core"
```

Run only the oracle for the cut being measured. C3's comparison tool is added
and unit-tested in C3a before the schema changes, so C3a itself never depends
on an unreviewed ad hoc projection. Generated C remains byte-identical through
the entire C3 train.

C5b's raw-identical symbol-table cut still uses `--require-identical`. C5c
intentionally changes C identifier spelling: omit `--require-identical`, then
compare the retained artifacts before runtime/codegen gates:

```bash
benchmarks/normalize_generated_c_symbols \
  "$series_root/parent.c" "$series_root/candidate.c"
```

Do not report wall time as the primary evidence.

Metrics by claim:

| Claim | Required evidence |
| --- | --- |
| fewer name lookups | exact counters and string hash/equality sample |
| fewer allocations | phase and whole-compile allocation rows; retained bytes |
| cheaper identity | retired instructions and generated C around comparison/table lookup |
| smaller representation | generated C layout, ARC/cleanup sample, construction count |
| faster user-visible compile | matched retired instructions plus latency confirmation |

Identity oracles:

- byte-identical generated C until output spelling changes;
- normalized generated C for ID-derived symbols;
- exact diagnostic and reflection text;
- formatter corpus for source-spelling changes;
- Core/typed JSON round-trip where those formats are intentionally retained;
- runtime, leak, sanitizer, compiler-blorp, compiler-tools, and codegen audit
  for representation/emission changes.

Run the narrow owner suite while iterating, then at least:

```bash
scripts/compiler-check --changed
scripts/test --serial compiler-blorp compiler-tools
scripts/test leak
scripts/test compiler-core-sanitize
```

Add LSP definition/reference/rename/highlight gates for C2x or C9 if the LSP
consumes the migrated typed products. Do not claim unrun platform coverage.

## Stop rules

Stop and redesign a cut when any of the following occurs:

- a second permanent string/ID representation appears instead of replacing
  the first;
- a display lookup enters a per-node hot loop;
- an immutable catalog field adds retain/release traffic to every recursive
  call or pass-state update;
- an ID is inferred from a string prefix, hash, source formatting, pointer, or
  other heuristic;
- a pass rescans the whole program to find an allocation frontier that should
  have been carried;
- a dense list must allocate proportional to a sparse/high ID range;
- generated C differs before the named symbol-projection step without a
  correctness bug and regression test explaining why;
- diagnostics become less precise because the display table lost provenance;
- a performance cut regresses either whole-compile allocations or retired
  instructions materially without a larger measured benefit;
- the implementation needs compatibility wrappers with no scheduled deletion
  gate.

A negative experiment is valid evidence. Record why the representation failed
and keep the prior authoritative path rather than landing an unmeasured second
system.

## Expected payoff

ID keying alone is principally an instruction and correctness change;
dictionary probes generally do not allocate. The allocation payoff arrives
when managed strings and `CoreVar` records leave every variable occurrence.

Current evidence suggests this order of magnitude for a full self-compile:

| Completed scope | Expected effect, not an acceptance promise |
| --- | --- |
| ID-only equality and selected Core maps | roughly 0.1-0.8% instructions; allocations mostly flat |
| ID-derived emission and removal of backend semantic name work | additional backend instruction reduction, workload-dependent |
| fixed-layout Core variable identity with display side table | plausibly 1-3% whole-compile instructions and 1-3% allocations |
| consistent post-discovery ID use through typecheck, Core, and backend | plausibly 2-4% whole-compile instructions, with several-percent allocation upside |

The architectural payoff is at least as important: exact shadowing semantics,
one resolution result reused by every stage, smaller facts tables, simpler
Perceus/DCE/closure indexes, no accidental semantic decisions in printers,
and a clean base for incremental compilation and language-server reuse.

## Completion criteria

The migration is complete when:

- every semantic entity downstream of its resolution point is referenced by a
  typed ID;
- `CoreVar` no longer contains a `String`, optional definition record, or
  name-derived identity;
- every binder and use has a strict, validated `ResolvedValueId`;
- ordinary emitted names are derived from IDs and built once;
- source spellings live only in canonical frontend/definition/binding display
  tables;
- persisted compiler facts have one normalized logical authority with typed
  keys; optional and relational facts live in side/edge tables rather than
  duplicated node payloads;
- all spelling reads are confined to documented display, reflection, or ABI
  boundaries;
- no Core/backend name-only fallback can affect semantics;
- diagnostics, formatting, reflection, and foreign/exported ABI remain exact;
- the final frozen self-compile records generated-C identity, tests,
  allocations, retired instructions, and limitations in a retained benchmark
  result;
- every implementation cut was handed off with the required logical schema,
  literate before/builder/consumer/deletion examples, file ownership, fast
  loop, acceptance gates, and stop/consult conditions.

Historical Core-only steps 0-2 (Perceus attribution, authored lowering IDs,
and the report-only invariant) remain useful foundation, but their remaining
steps are superseded by A2-A8 above. Git history and
`benchmarks/results/perceus_allocation_attribution_2026-09-22.md` preserve the
original evidence.

### Legacy step references in source comments

Existing source comments still use the original roadmap's step numbers. Keep
this mapping until the owning implementation cut updates each comment:

| Legacy step | Meaning | New owner |
| --- | --- | --- |
| 0 | Perceus per-helper allocation attribution | C0a evidence |
| 1 | source-span-derived positive IDs for authored lowering binders | replaced by A2-A3 resolved binding IDs |
| 2 | report-only Core binder identity invariant | strengthened and made strict by A4 |
| 3 | Perceus variable catalogs keyed by exact identity | A7 Perceus family |
| 4 | closure captures carry exact variable identity | A7 closure family |
| 5 | synthetic binders mint IDs instead of baking uniqueness into strings | A4 |
| 6 | C identifiers derive from identity and spellings move to a table | A5 and A8 |
