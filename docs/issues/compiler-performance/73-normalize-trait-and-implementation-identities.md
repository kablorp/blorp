# Issue 73: Normalize Trait And Implementation Identities

**Status:** Implemented

**Roadmap:** [Normalized Compilation Database Roadmap](NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)

**Dependencies:**

- Issue 61B establishes canonical graph definition rows.
- Issue 69 establishes definition-backed callable identity.
- Issue 70 establishes definition-backed nominal type identity.
- Issues 71-72 establish the scalar global/field patterns and finish their
  affected module views.

**Checkpoint:** This closes the first Horizon 2 definition/declaration identity
tranche. Checked-body and semantic-occurrence tables remain later work.

## Objective

Replace managed graph `TraitId`, `TraitMethodId`, and `ImplId` identities with
category-safe scalar or small numeric values, while preserving an explicit
builtin trait domain. Publish the exact trait-method and
implementation-to-trait/method relationships once, and remove redundant
owner/name/span copies and overlapping lookup indexes.

The target shape is:

```text
Graph TraitId -> DefinitionId -> owner ModuleId
Builtin TraitId -> explicit BuiltinTraitId
ImplId -> DefinitionId -> owner ModuleId
TraitMethodId -> exact owner TraitId + source method slot

TraitId -> ordered TraitMethodId
TraitId -> ordered supertrait TraitId
ImplId -> implemented TraitId
ImplId -> receiver TypeId / resolved receiver shape
ImplId -> ordered explicit/default CallableId methods
```

This issue does not make every relation a dictionary. A nested ordered list or
aligned column is already a valid relation when it has one owner and serves the
actual query efficiently.

## Current Production Shape

`declaration_skeleton.brp` currently uses:

```blorp
private record RuntimeDeclarationIdRep {
	structural: StructuralDeclarationIdRep,
	definition_id: Int
}

opaque type ImplId = RuntimeDeclarationIdRep

private union TraitIdRep:
	GraphTraitId(RuntimeDeclarationIdRep)
	CompilerBuiltinTraitId(String, SourceSpan)

private record TraitMethodIdRep {
	owner: TraitId,
	index: Int,
	structural: StructuralDeclarationIdRep
}
```

Graph traits and implementations therefore retain a raw definition integer
plus module/name/owner/span. Trait methods retain owner and slot plus another
structural copy. Builtin trait identity is represented by source spelling and
span rather than an explicit builtin ID.

The accepted trait/implementation authority and header graphs contain indexes
such as:

```text
trait_indices_by_module_and_definition_id
implementation_indices_by_module_and_definition_id
implementation_indices_by_satisfied_trait_index
trait_method_index_by_owner_and_slot
implementation_method_index_by_owner_and_callable
```

Some are canonical query paths; others may duplicate relationships already in
rows or exist only for validation/tests. The issue must classify them from
production readers before choosing a target.

## Required Reading And Audit

Read before editing:

- Issues 68-72 final results and generated-C findings;
- trait/implementation reservation and default-method collection in
  `graph/definition_index.brp`;
- all trait/method/implementation IDs and skeleton construction in
  `headers/declaration_skeleton.brp`;
- `headers/trait_headers.brp`, `headers/implementation_headers.brp`, and
  `headers/callable_headers.brp`;
- `type_system/accepted_trait_implementation_authority.brp`;
- trait bounds, method resolution, implementation selection, UFCS, and
  inference readers;
- builtin trait construction in `type_system/builtins.brp` and
  `type_system/env.brp`;
- semantic occurrence, typed-AST JSON, LSP, CTFE, and Core-lowering
  projections; and
- trait topology, implementation, callable, ambiguity/coherence, replay,
  leak, sanitizer, and profile tests.

Produce a relationship/index ledger:

| Relation/index | Canonical owner today | Builders | Production readers | Order | Keep/change/delete |
| --- | --- | --- | --- | --- | --- |
| trait -> methods | trait header row | audit | audit | source slot | audit |
| impl -> trait | implementation header | audit | matching/projection | declaration | canonical typed relation |
| impl -> methods | implementation header | audit | dispatch/projection | explicit/default order | canonical typed relation |
| trait-definition lookup | authority index | audit | audit | n/a | scalar ID/direct row if possible |

The completed ledger must cover all fields and indexes in the accepted
authority, not only names containing `id`.

### Completed reader ledger

| Relation/index | Production query | Decision |
| --- | --- | --- |
| trait topology `headers` | ordered topology traversal and exact trait lookup | keep as canonical rows |
| trait topology `header_index_by_definition_id` | exact graph-trait lookup | keep; graph `TraitId` is its definition ID |
| trait row `methods` / `supertraits` | method resolution and inheritance traversal | keep; these are the ordered canonical relations |
| implementation header `header_index_by_definition_id` | none | delete |
| implementation header `index_by_trait_definition_id` | test-only candidate lookup | delete; accepted-authority selection owns the production reverse query |
| accepted `traits` / `implementations` | all accepted semantic projections | keep as canonical rows |
| accepted trait/implementation module lists | source-order module visibility projection | keep |
| accepted nested module-plus-definition indexes | exact ID lookup | replace with one graph-wide `DefinitionId -> row` index per category |
| accepted builtin trait string identity index | builtin link lookup | replace with the builtin registry's dense numeric identity |
| `implementation_trait_method_ids` | exact implementation-method to trait-slot dispatch relation | keep; it is an ordered aligned column |
| satisfied/conflicting implementation adjacency | visible selection and coherence queries | keep; both have production readers |
| semantic-name and qualified module/method maps | source-name and UFCS queries | keep |
| compiler implementation string identity map | builtin implementation lookup | replace with the builtin registry's dense numeric identity |

Generated-C inspection showed that a source union around scalar graph/builtin
variants is managed in the current compiler. The implementation therefore uses
one opaque `Int` domain: non-negative values are category-checked graph
`DefinitionId`s, and negative values encode `-(builtin_registry_id + 1)`.
Construction and decoding remain behind named APIs. This preserves an explicit,
dense builtin domain while keeping every `TraitId` unboxed; using the illustrative
union from the target design would retain the allocation this issue removes.

`ImplInstance.for_type` remains the canonical semantic receiver. Replacing it
with `ResolvedTypeShape` here would change the accepted-authority boundary and
duplicate later conversion work; Issue 73 normalizes implementation identity
and indexes without changing that receiver contract. A full-tree reader audit
also found no `TraitId`, `TraitMethodId`, or `ImplId` consumer beyond Stage 06,
so CTFE/Core require verification but no compatibility projection.

## Target Identity Design

### Graph and builtin traits

Keep the source/builtin distinction explicit:

```blorp
opaque type GraphTraitId = DefinitionId
opaque type BuiltinTraitId = Int

union TraitId:
	GraphTrait(GraphTraitId)
	BuiltinTrait(BuiltinTraitId)
```

Only a `TraitDefinition` row can construct `GraphTraitId`. Only the builtin
registry can construct `BuiltinTraitId`. The builtin integer must be a dense
registry ID or named enum/domain, not an arbitrary raw definition integer.

Graph trait owner/name/span come from `DefinitionTable`. Builtin display name
and diagnostics come from the builtin trait table. Neither ID carries a managed
string, span, module table, or environment.

### Implementations

Make `ImplId` a checked scalar:

```blorp
opaque type ImplId = DefinitionId
```

An implementation's trait and receiver are semantic relationships, not ID
fields:

```blorp
record AcceptedImplementationRow {
	id: ImplId,
	trait_id: TraitId,
	receiver: ResolvedTypeShape,
	methods: List[ImplementationMethodRow],
	visibility: DeclarationVisibility
}
```

Keep category-specific payloads in the implementation row. Remove repeated
module/name/span identity and raw definition integers.

### Trait methods

Trait methods without a runtime body do not necessarily have a runtime
definition ID. Do not insert fabricated IDs into the Stage 06/Core allocation
frontier.

Use either:

```blorp
struct TraitMethodId {
	owner: TraitId,
	slot: Int
}
```

or a dense `TraitMethodId` into an immutable method table. Prefer the two-
integer form if generated C keeps it unboxed and hot matching otherwise needs
an extra table read. Prefer the dense form if IDs are copied much more often
than owner/slot is queried and the focused profile proves a benefit.

The method table owns source name/span, signature, category, and body/default
facts. `TraitMethodId` does not repeat a structural identity.

## Relationship Ownership

Publish each relationship at its natural accepted owner:

- trait row: ordered methods and supertraits;
- implementation row: implemented trait, receiver, ordered methods;
- implementation method row: exact `CallableId` and explicit/default category;
- module view: visible `TraitId` and `ImplId` locators.

Where a query begins with a resolved ID, use scalar addressing or an integer
index. Where a query begins with source spelling or a receiver shape, keep the
minimal source/shape index required by that query.

Do not retain both:

```text
implementation row -> trait ID
```

and a separately rebuilt `implementation trait by impl ID` dictionary unless a
measured consumer cannot read the row efficiently. Reverse trait-to-impl
adjacency may remain when implementation selection genuinely queries it.

All adjacency preserves current order, including:

- trait source method slots;
- declared supertrait order;
- implementation declaration order;
- explicit method order;
- synthesized default method order; and
- overload/candidate precedence.

## Module Views And Accepted Boundary

Trait/implementation module views should contain ordered IDs or compact
locators and only the source spellings needed for source-name queries. They
must not copy full trait/implementation records or owner paths.

Only accepted rows enter the authority. Reserved but rejected graph traits and
implementations remain addressable for diagnostics through definition/source
products, not accepted semantic tables. Builtin traits enter through their
explicit builtin table and remain distinguishable from graph definitions.

## Scope

In scope:

- unboxed graph `TraitId` and `ImplId`;
- explicit unboxed builtin trait identity;
- compact exact `TraitMethodId`;
- accepted trait/method/supertrait and implementation/trait/receiver/method
  relationships;
- scalar exact-ID indexes and justified reverse selection indexes;
- ID/locator-only trait and implementation module views;
- default and explicit implementation method callable identities;
- semantic occurrence, typed-AST/LSP, CTFE, and Core projection updates; and
- deletion of structural IDs, descriptive owner columns, and redundant
  indexes.

Out of scope:

- changing trait coherence, matching, specialization, supertrait, default
  method, UFCS, or inference semantics;
- assigning runtime definition IDs to declaration-only trait methods;
- changing callable/type/global/field identity established by Issues 69-72;
- interning receiver or semantic types;
- changing Core trait resolution or pass order;
- changing external schemas;
- checked-body or semantic-reference table work; and
- caches/invalidation.

## Implementation Sequence

### 1. Pin identity and relationship behavior

Add failing structural tests for unboxed graph IDs, explicit builtin IDs, and
trait method owner/slot identity. Record exact relation/index construction and
query counts in the existing trait topology profile.

### 2. Cut over graph and builtin trait IDs

Claim graph trait rows from `DefinitionTable`, issue builtin IDs from the
builtin registry, and convert trait headers/bounds/topology. Delete managed
name/span identity in the same slice.

### 3. Compact trait method IDs

Choose owner/slot or dense table ID using generated C and focused measurement.
Move name/span/signature to the method row and convert all equality/index APIs.

### 4. Cut over implementation IDs

Claim `ImplDefinition` rows, convert header and accepted authority products,
and publish the exact implementation relationships. Preserve explicit/default
method construction and callable IDs.

### 5. Consolidate indexes and module views

Use the reader ledger to delete duplicate owner/module/definition indexes.
Keep the minimal receiver/trait/name access paths used by production. Convert
module views to IDs/locators.

### 6. Convert projections and delete residue

Update infer/UFCS/occurrence/JSON/LSP/CTFE/Core consumers. Materialize source
facts only at diagnostics/protocol/naming boundaries. Remove structural
helpers and impossible test constructors.

### 7. Measure the issue and cumulative checkpoint

Measure this issue against its immediate parent. Then compare the complete
Issues 68-73 state to the post-Issue-58 control using a compatible bootstrap,
command, and stop point. Do not combine incompatible percentages.

## TDD And Fast Feedback Loop

Iterate with:

```bash
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_declaration_skeleton_graph.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_callable_headers.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_declaration_catalog.brp
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp
scripts/compiler-check --changed
```

If Issue 68 removed the old `test_declaration_catalog.brp`, use the current
manifest-owned accepted trait/implementation fixture; do not recreate the
dormant catalog for this issue.

Final gates:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test compiler-core-sanitize
scripts/test leak
git diff --check
```

Core sanitizer coverage is proportionate only if the migrated IDs cross into
Core-lowering or Stage 09 structures.

Inspect generated C and confirm:

- graph trait and implementation IDs are unboxed integers;
- builtin trait IDs carry no managed strings/spans;
- trait method IDs contain only the chosen numeric identity;
- table pointers are retained by products, not IDs;
- equality and exact lookup do not compare module/name/span; and
- removed indexes are not reconstructed under new names.

## Performance Harness

Use:

- `compiler_trait_topology_profile` for traits, methods, supertraits,
  implementations, and selection;
- `compiler_callable_header_profile` for default/explicit method callables;
- `compiler_typecheck_phase_profile` for header, accepted authority, body, and
  projection checkpoints;
- `compiler_frontend_declaration_catalog_profile` for production authority and
  module-view scaling; and
- `compiler_typecheck_replay` for exact Phase 01-06 output, allocations,
  retired instructions, and peak memory.

Vary:

- modules;
- traits and methods per trait;
- supertrait edge density;
- implementations per trait/receiver;
- explicit/default methods;
- same-name traits across modules;
- builtin versus graph traits; and
- resolved-ID, source-name, and receiver-selection query counts.

Record exact identity constructions/copies, relation rows, reverse-index rows,
source/storage keys, index builds/probes, candidates visited, allocations,
releases, retained bytes, retired instructions, diagnostic/order checksums, and
definition frontier.

Require fewer allocations or retired instructions in a trait/implementation-
heavy shape. The cumulative Issues 68-73 checkpoint must reduce managed
identity/string/index work and must not regress Phase 01-06 latency or peak RSS
materially.

## Acceptance Criteria

- Graph traits and implementations use category-checked, unboxed IDs backed by
  their existing definition rows.
- Builtin traits use an explicit unboxed builtin domain, not name/span identity
  or a magic graph ID.
- Trait method identity is exact and numeric without a copied structural
  record or fabricated runtime definition ID.
- Trait-method, supertrait, implementation-trait/receiver, and implementation-
  method relationships have one canonical owner and exact order.
- Reverse/name/receiver indexes exist only for named production queries and
  validate against canonical rows.
- Trait/implementation module views contain IDs/locators plus necessary source
  spellings, not copied owner identities.
- Accepted/rejected and graph/builtin distinctions remain explicit.
- Trait coherence, matching, bounds, default methods, UFCS, visibility,
  ambiguity, inference, diagnostics, and generated callable order are
  unchanged.
- Typed-AST, semantic/LSP, CTFE, Core, and replay output remain exact.
- Generated C proves unboxed IDs and no per-ID table retention.
- Production source deletes the old structural identity representation and
  redundant indexes rather than retaining parallel compatibility state.
- Focused workloads reduce allocations or retired instructions; the
  cumulative checkpoint reduces managed identity/string/index work with no
  material latency or RSS regression.
- Focused, changed, Stage 06, compiler, leak, and proportionate sanitizer gates
  pass.

## Implementation Result

Graph `TraitId` and `ImplId` are now category-checked scalar identities backed
by their existing `DefinitionTable` rows. Graph traits occupy the non-negative
definition-ID domain; builtin traits use an opaque `BuiltinTraitId` and occupy
the explicit negative encoding `-(builtin_registry_id + 1)`. The builtin
registry owns the dense numeric ID to name relation, so trait identity no
longer retains a source name or span.

`TraitMethodId` is now the unboxed two-integer `{ owner, index }` value selected
by the issue. Method spelling, source, category, and signature remain on the
ordered trait-method row. One generated-C ownership edge required an additional
boundary cleanup: data-carrying unions now store the scalar owner and slot
separately rather than boxing `TraitMethodId`. This preserves the compact value
representation in records, lists, and calls without leaking a compiler-created
box from union payloads.

The accepted table now uses one graph-wide definition-ID index for traits and
one for implementations. Builtin trait and compiler implementation lookup use
the numeric builtin identity. Ordered method, supertrait, satisfied-trait, and
conflict relations remain canonical. Two implementation-header indexes were
deleted after the reader audit found no production exact-ID consumer and only
a test-only candidate consumer; production implementation selection continues
to use the accepted authority's justified reverse indexes.

Diagnostics materialize names and spans from definition/source rows at their
boundary instead of retaining those values in IDs. A full-tree reader audit
found no migrated ID crossing into CTFE or Core, so no compatibility projection
or Core sanitizer expansion was added.

Generated C confirms graph trait and implementation IDs are emitted as `long`,
and `TraitMethodIdRep` is the inline two-`long` struct. The former managed
`RuntimeDeclarationIdRep`, structural identity copies, and string/span builtin
trait variants are absent.

Clean `-O2` before/after measurements against the immediate parent used the
same 256-trait, four-method, 100-iteration topology workload and produced the
same checksum:

| Measurement | Parent | Issue 73 | Delta |
| --- | ---: | ---: | ---: |
| measured topology window | 291,870 us | 276,331 us | -5.3% |
| allocations | 3,740,700 | 3,408,800 | -8.9% |
| retained objects | 9,214 | 9,214 | unchanged |

A warmed Stage 01-06 self-check of the same parent source remained neutral:
8.37 s / 138.90 billion retired instructions / 843.5 MB peak RSS for the
parent versus 8.41 s / 139.32 billion instructions / 842.8 MB for Issue 73.
That is +0.5% wall time, +0.3% instructions, and -0.1% peak RSS, all within the
issue's no-material-regression boundary while the trait-heavy target shows a
clear allocation and latency reduction.

Validation completed before acceptance:

- `scripts/compiler-check --changed`: 9 sources, 20 suites, and 2 checks passed;
- `scripts/compiler-check --stage typecheck`: 43 sources, 37 suites, and 2
  checks passed;
- focused implementation-header and trait-topology leak checks passed with
  zero leaked bytes;
- the frozen-tree ordinary compiler, ASan/UBSan compiler, and leak gates passed
  4,358, 3,659, and 886 tests respectively: 8,903 passed and zero failed;
- final generated C retained the scalar/inline representations and contained
  none of the deleted managed identity types;
- independent production review reported zero findings; and
- `git diff --check` passed.

The final diff is separated by ownership: production `+698/-827` (net -129),
tests `+132/-107` (net +25), and benchmark fixtures `+9/-6` (net +3). No
compatibility identity path, test-only production lookup, or duplicate
receiver-head column remains.

## Stop Conditions

Stop and consult before:

- changing trait coherence, selection, default methods, UFCS, or typechecking
  semantics;
- assigning fabricated runtime definition IDs to trait methods or builtins;
- retaining structural and scalar identities together;
- adding per-ID managed provenance;
- adding speculative reverse indexes or caches;
- changing Core pass order, C names, ABI, or external schemas; or
- broadening into bodies, semantic reference tables, CTFE values, semantic type
  interning, or Core expression arenas.
