# Cut Over Values, Traits, And Implementations To The Declaration Catalog

**Status:** In progress; global and callable production cutovers implemented, trait/implementation cutovers pending

## Trait And Implementation Authority Foundation

The first bounded Issue 22 slice adds the authority/index contract needed by
the production cutover without changing body inference yet:

- `stage_05_types/trait_implementation_authority.brp` owns opaque accepted
  trait and implementation indexes. Entries retain final `TraitDef`,
  `ImplInstance`, and `ImplMethodInfo`-compatible semantic payloads. Prepared
  entries carry both owner-local and canonical imported payloads because the
  existing header conversion intentionally represents owner-local nominal
  names differently from imported names. Each module index selects the local
  payload only for the declaration owner and the canonical payload otherwise,
  including method signatures and dimension constraints.
- Exact trait, trait-method, implementation, and implementation-method queries
  validate the full module, definition, owner, slot/callable, and source-name
  identity. Invisible private imported entries never enter the index.
- Source and qualified trait queries preserve explicit ambiguity and resolve a
  qualified alias to `ModuleIdentity` before consulting the module/name index.
- Ordinary trait-method and UFCS candidate orders are stored independently.
- Implementation candidate lists are partitioned by exact trait identity and a
  coarse receiver-head category. Receiver head is only a search accelerator:
  integration must still run the existing receiver compatibility,
  type-parameter-bound, and supertrait checks in deterministic candidate order.
- Query misses use dictionary `get` matching and return immediately; they do
  not construct default dictionaries or lists merely to probe an absent key.
- Projection construction groups accepted entries by owner in one graph pass,
  with exact trait identity and public module/name indexes plus a separate
  builtin implementation bucket. A module overlay visits only its local
  bucket, directly imported or qualified public buckets, builtin
  implementations, and the exact supertrait closure it requires. It never
  rescans all graph declarations per module.
- Hot grouping, overlay, candidate, and method buckets accumulate in reverse
  with constant-time singleton concatenation and normalize order once at the
  index boundary. They do not repeatedly append to persistent lists as a
  declaration bucket grows.
- Transient build observations report grouped entry counts and per-module
  bucket/closure/index-item visits. Focused scaling coverage separately grows
  unrelated graph entries and one module's own trait, implementation, and
  method counts. The former leaves the target overlay unchanged; the latter
  produces exactly proportional grouping, method, UFCS, candidate-index, and
  implementation-method work. Ordinary production builders skip per-module
  observation materialization.
- `stage_06_typecheck/headers/trait_implementation_projection.brp` validates
  prepared semantic payload entries against `TraitTopologyGraph` and
  `ImplementationHeaderGraph`, then builds one index per bound module using
  `BoundModule`/`ModuleView` visibility. It intentionally does not duplicate
  resource-argument policy derivation or implementation matching.
- `stage_06_typecheck/headers/trait_implementation_preparation.brp` is the
  narrow bridge from already validated owner-local `TraitDef` and
  `ImplInstance` payloads to those dual entries. It reuses accepted resolved
  type shapes for canonical signatures, receivers, and dimension constraints;
  copies the existing resource policy, parameter names, bounds, and callable
  target metadata; and pairs explicit implementation methods by exact accepted
  callable ID. It does not derive policy, synthesize targets, or perform
  implementation matching.
- Default trait methods remain trait-authority slots and signatures.
  Implementation authority contains only the ordered explicit implementation
  method subsequence. This avoids fabricating `ImplMethodInfo` values for
  inherited defaults and preserves the existing trait-method ownership model.

The integration owner must supply the final prepared method payload at the
existing validation/ID-claim boundary, then replace accepted `Env` publication
and reads. Until that integration lands, this foundation is not the Issue 22
valid merge point described below and makes no end-to-end performance claim.

## Context And Dependencies

Issue 21 establishes the catalog and module view as the sole authority for
graph-owned types and constructors. This issue migrates the remaining accepted
declaration categories: functions, globals, overloads, traits,
implementations, implementation methods, and UFCS candidates.

This is the final semantic cutover. At completion, `Env` remains responsible
for lexical body state, not for storing a module graph's accepted declarations.
Issue 23 then removes remaining legacy construction code and performs final
measurement.

## Global And Callable Authority Foundation

The first bounded Issue 22 slice adds category-specific accepted indexes and
product-level projection builders without changing the active body typecheck
path yet:

- `GlobalValueIndex` keys exact globals by owner `ModuleIdentity` plus
  definition ID and stores source-visible and module-qualified bindings
  separately. A binding selects the owner-local or canonical semantic type and
  its corresponding module path.
- `CallableValueIndex` uses the same nominal exact identity and stores separate
  ordinary, UFCS, and module-qualified candidate lists. Each binding selects
  the owner-local or canonical function signature, type parameters, dimension
  constraints, and local/imported module-path metadata.
- The projection builders group accepted products once by owner identity and
  canonical module path. A module overlay visits only its local declarations
  and declarations from directly imported modules; unrelated graph growth does
  not increase overlay declaration visits.
- Exact lookup in a module overlay is fail-closed. It includes local and public
  direct/selective/qualified-direct declarations, but it does not inherit a
  graph-wide exact fallback. Private and transitive value identities remain
  unavailable.
- Qualified lookup resolves the caller's existing `ModuleView` alias and then
  queries the shared canonical module-name index. The projection does not
  retain or copy every caller view.
- Query misses return `Option` directly. Callable miss paths do not synthesize
  empty candidate lists.

Focused tests cover wrong-module same-integer IDs, source-versus-canonical
named types and dimension constraints, local/imported module paths, direct and
selective imports, explicit qualified-only imports, deterministic overload and
UFCS ordering, private/transitive rejection, and stable overlay visit counts
under unrelated graph growth.

The global and callable foundations are now integrated into `decl.brp`,
`infer.brp`, and `module_view.brp`. Accepted body preparation no longer
publishes either category into `Env`; provisional initializer and standalone
paths retain the legacy publication path. Trait and implementation foundations
remain unintegrated until their corresponding reads and writes can be removed
in the same vertical slice.

Before callable integration, the graph owner must provide already-validated
metadata that `CallableHeaderGraph` alone does not currently retain:

- resource argument policy;
- loop-producer metadata;
- debug-only status; and
- both owner-local and canonical semantic signatures, type parameters, and
  dimension constraints.

These facts must come from the existing accepted header/registration products
or be added at their current construction boundary. The projection builder must
not re-run declaration analysis or silently substitute defaults. Completed
global products already provide source and canonical binding types and can be
projected directly.

`stage_06_typecheck/headers/callable_entry_preparation.brp` is the bounded
preparation helper for the callable side of this boundary. It converts one
already-validated owner-local `FuncSymbol` plus its accepted `CallableHeader`,
`TypeHeaderGraph`, owner `ModuleIdentity`, and canonical module path into the
`AcceptedCallableEntry` consumed by `callable_value_projection.brp`. The helper
reuses the local symbol exactly for source signature, parameter names, purity,
origin, resource policy, loop producer, debug status, and bound parameters. It
computes only the canonical imported semantic signature and dimension
constraints from the existing imported resolved-shape conversion API, validates
owner/definition/origin/arity/purity consistency, and returns `Result` instead
of publishing defaults.

## Global Production Cutover

The first production vertical slice now makes `GlobalValueProjection`
authoritative for accepted global reads while preserving initializer and
standalone provisional behavior:

- `complete_typecheck_graph` projects only successfully completed global
  headers once and stores the result in `TypecheckGraphFacts`. Accepted and
  recoverable graphs share that product; failed recoverable globals are absent.
- Each accepted or CTFE module selects its `GlobalValueIndex` by exact
  `ModuleIdentity` and attaches it to the opaque `ModuleView`. A missing module
  projection records a deterministic internal error and attaches an empty
  authoritative index rather than falling back to `Env`.
- Bare lookup preserves lexical/current-module and explicit selective-import
  precedence before consulting the accepted global index. Qualified lookup
  uses the module alias's canonical path. Mutable global assignment uses the
  same authoritative binding and keeps module-assignment purity behavior.
- Direct bare, selective alias, qualified-only, local, private, and transitive
  visibility are covered through accepted body checking. The bounded module
  overlay contains qualified entries for public direct imports, but only a
  default alias publishes their bare names.
- Accepted module preparation omits imported global headers, local global
  headers, and completed global publication into `Env`. Initializer checking
  still uses the legacy publication path because it is provisional and must
  resolve dependencies while global completion is being built.
- The declaration preparation observation now reports
  `global_header_installations`. Canonical accepted and CTFE preparation assert
  zero installations while retaining a nonzero `unique_globals` denominator;
  initializer preparation continues to report its required installations.
- Projection input accumulation prepends and reverses once, preserving
  completed-header order without quadratic persistent-list appends.

Production replay remains intentionally deferred to the integration
coordinator. This slice makes no end-to-end latency claim until that controlled
baseline/candidate replay is run. The architectural acceptance condition is
already enforced: accepted global reads do not use an `Env` fallback and the
accepted path no longer retains duplicate global symbols there.

## Callable Production Cutover

The second production vertical slice makes `CallableValueProjection`
authoritative for accepted source callables while leaving trait and
implementation methods on their existing path:

- Accepted owner-local `FuncSymbol` products are harvested once at the
  validated initializer/ID-claim boundary and converted with
  `prepare_accepted_callable_entry_from_local_symbol`. The projection does not
  re-run declaration analysis or synthesize resource, loop-producer, debug,
  purity, parameter, type-parameter, or dimension metadata.
- `TypecheckGraphFacts` owns one projection shared by accepted and recoverable
  graphs. Accepted and CTFE module preparation attaches the exact module index
  to `ModuleView`; a missing index records an internal diagnostic and installs
  an empty authoritative index rather than falling back to `Env`.
- Each binding retains its selected owner-local or canonical `FuncSymbol` and
  `OverloadEntry`. The index also retains ordered overload lists for bare,
  qualified, ordinary UFCS, and qualified UFCS queries, avoiding per-query
  record reconstruction and list mapping.
- Bare and qualified function lookup, overload resolution, exact callable
  metadata by definition ID, debug-only checks, and ordinary UFCS lookup read
  the accepted index after lexical/current-scope precedence. Trait and
  implementation-method readers remain unchanged.
- A present callable index is fail-closed. `Env` fallback is available only to
  provisional initializer or standalone paths where the accepted index is
  absent. Direct, selective, qualified-only, private, and transitive visibility
  remain represented by the existing `ModuleView`-driven projection.
- Accepted and CTFE preparation omit both imported and local callable header
  publication. Structural observations report zero
  `imported_callable_header_installations` and zero
  `local_callable_header_installations` with nonzero `unique_callables`;
  initializer preparation still reports the required provisional installs.

Focused validation covers callable index ordering/identity, accepted import
and canonical-signature behavior, overload and UFCS inference, resource and
debug metadata, recovery, and CTFE. Production replay remains coordinator-owned
and is not claimed by this slice.

## Problem Statement

Callable and implementation lookup currently combines several meanings:

- exact identity lookup;
- source-name candidate discovery;
- overload ordering;
- UFCS eligibility;
- trait inheritance and method ownership;
- implementation coherence and privacy; and
- local lexical shadowing.

Repeatedly publishing these declarations into persistent module scopes is
expensive, but replacing the path with one flat dictionary would be incorrect.
The catalog must expose explicit query categories and the module view must
preserve visibility and precedence. Every migrated family must lose its legacy
storage immediately so that disagreement cannot be hidden by fallback logic.

## Goal

After this issue:

1. all accepted graph declarations are stored once in the catalog;
2. module views decide source visibility without copying full declaration
   records;
3. exact callable/global/trait/implementation lookups use nominal IDs;
4. overload and UFCS candidate order remains deterministic;
5. implementation coherence and privacy behavior is unchanged;
6. `Env` contains only lexical scopes, body-local variables, refinements, type
   parameters, and other genuinely local facts; and
7. structural counters prove that graph declaration installation is zero.

## Non-Goals

- Do not redesign overload, UFCS, or trait semantics.
- Do not add global memoization of arbitrary inference results.
- Do not merge source names with nominal identity.
- Do not keep legacy reads as a safety fallback.
- Do not move lexical variables into the catalog.
- Do not fuse this work with Core lowering or backend identity changes.

## Phase 1: Classify Every Query

Inventory production consumers of at least:

- module/global variable lookup;
- module function lookup;
- callable and implementation method lookup by definition ID;
- source-name function and global lookup;
- overload set lookup and pure/impure filtering;
- UFCS method discovery;
- trait lookup, inherited trait traversal, and trait method lookup;
- implementation lookup and conflict detection;
- private implementation lookup;
- record-field based callable discovery if it shares the symbol store;
- foreign/debug/resource callable metadata; and
- accepted callable-header/module-header publication.

For every consumer, record:

| Consumer | Category | Exact or source-name | Visibility input | Ordering requirement | Replacement |
| --- | --- | --- | --- | --- | --- |

Separate lexical lookup from graph lookup. A local variable named like a
function is not a catalog ambiguity; lexical precedence decides it before
catalog candidate selection.

## Phase 2: Define Narrow Query APIs

The opaque catalog and module view need category-specific operations. The
shape should resemble:

```blorp
pure func declaration_catalog_callable(
	catalog: AcceptedDeclarationCatalog,
	callable_id: CatalogCallableId
) -> Option[AcceptedCallableDeclaration]

pure func module_declaration_view_callable_candidates(
	view: ModuleDeclarationView,
	catalog: AcceptedDeclarationCatalog,
	name: String
) -> List[CatalogCallableId]

pure func module_declaration_view_ufcs_candidates(
	view: ModuleDeclarationView,
	catalog: AcceptedDeclarationCatalog,
	name: String
) -> List[CatalogCallableId]

pure func declaration_catalog_impl(
	catalog: AcceptedDeclarationCatalog,
	impl_id: CatalogImplId
) -> Option[AcceptedImplementation]
```

Use the repository's final nominal types and error model. Exact APIs should be
constant-time direct lookups. Candidate APIs may return ordered IDs but must
not copy complete symbols, parsed declarations, or environments.

Represent these distinctions explicitly:

- local declaration versus imported declaration;
- direct versus qualified visibility;
- callable versus constructor versus global;
- trait method declaration versus implementation method;
- ordinary overload versus UFCS candidate;
- public versus private implementation; and
- exact match versus ambiguous source projection.

## Phase 3: Migrate Categories In This Order

### 3.1 Globals

Move exact and source-name global lookup first. Globals do not carry overload
or UFCS behavior, so they provide a bounded proof of value visibility and
lexical shadowing. Delete graph global symbols from `Env` after the cutover.

### 3.2 Exact Callable Identity

Move lookups by callable/definition identity. Validate category, owner module,
source scope, and declaration metadata at the catalog boundary. Remove exact
callable indexes duplicated in `Env` or `TypecheckState` when no consumers
remain.

### 3.3 Source Callable Candidates And Overloads

Move unqualified, selective, aliased, and qualified callable candidate lookup.
Preserve source order and existing tie-breaking. Then move overload filtering
and selected-overload identity. Avoid reconstructing `OverloadEntry` lists when
compact IDs plus catalog access are sufficient.

### 3.4 Traits And Trait Methods

Move trait identity/name lookup, supertrait edges, method slots, and trait
function collision checks. Keep method owner plus slot identity explicit; do
not infer method identity from a synthesized string.

### 3.5 Implementations And Coherence

Move exact implementation identity, trait/type candidate indexes, private
visibility, inherited-trait satisfaction, and conflict detection. Preserve the
existing deterministic diagnostic winner when several conflicts exist.

### 3.6 UFCS

Move UFCS candidate construction only after callables, traits, and
implementations are catalog-backed. Preserve module path order, source order,
purity constraints, type parameter bounds, and ambiguity behavior. Do not
rebuild display names or full overload records per query.

### 3.7 Remaining Callable Metadata

Move foreign ABI facts, debug-only restrictions, resource cleanup callables,
builtin status, purity, parameter counts, and any accepted header facts still
read through graph symbols.

For every subphase, migrate reads, delete old writes/storage, add a stale-symbol
scan, and run focused tests before continuing.

## Lexical `Env` End State

Write and test an explicit end-state inventory. `Env` may retain:

- lexical variables and functions introduced inside a body;
- nested scope ordering and shadowing;
- local type parameters and bounds;
- flow-sensitive refinements;
- temporary inference bindings;
- body-local diagnostics or facts that genuinely vary by body; and
- builtin lexical entries only if they cannot be represented as accepted graph
  declarations and the exception is documented.

It must not retain copied accepted module functions, globals, traits,
implementations, overload entries, UFCS entries, types, or constructors.

## TDD Coverage

Add or strengthen tests for:

- local variable shadows imported callable/global;
- local function shadows imported function under current language rules;
- direct, selective, aliased, and qualified callable imports;
- same-name overload ordering and deterministic selection;
- pure and impure overload separation;
- generic overload bounds and inferred type arguments;
- UFCS candidate order across local and imported modules;
- UFCS generic constructors and trait methods;
- trait inheritance and inherited method availability;
- trait method slot ownership;
- implementation selection and conflict diagnostics;
- private implementations staying module-local;
- duplicate imported names and exact ambiguity diagnostics;
- foreign, builtin, debug-only, and resource cleanup callables;
- exact callable/global/trait/impl wrong-category IDs failing closed;
- rejected declarations never entering candidate sets;
- error recovery not publishing partial headers; and
- callback/function-value paths preserving nominal callable identity.

Use exact expected diagnostics for should-fail fixtures. Add identity/order
assertions, not merely candidate counts.

## Structural Counters

Extend the Issue 15 counters with:

```text
catalog_callable_exact_queries
catalog_callable_candidate_queries
catalog_callable_candidate_visits
catalog_global_exact_queries
catalog_trait_exact_queries
catalog_impl_exact_queries
catalog_ufcs_queries
catalog_ufcs_candidate_visits
legacy_imported_callable_symbol_installs
legacy_imported_global_symbol_installs
legacy_imported_trait_symbol_installs
legacy_imported_impl_symbol_installs
legacy_local_graph_value_symbol_installs
```

At completion, every `legacy_*_installs` counter above and all type/constructor
legacy counters from Issue 21 must be zero. Exact-query work must be invariant
under unrelated graph growth. Candidate visits may grow only with candidates
that are semantically relevant to the queried source name/type.

## Performance Measurement

Use synthetic fixtures that vary independently:

- module count;
- functions and globals per module;
- overloads per source name;
- traits and supertrait depth;
- implementations per trait/type pair;
- UFCS candidates per name;
- duplicate names across modules; and
- import graph depth and fan-out.

For each axis, record setup/build and body-query windows separately. Calculate
empirical scaling exponents for declaration count and module count. Then run at
least three alternating production compiler typecheck replays with identical
responses.

Report elapsed time, named typecheck checkpoints, allocations/releases,
current objects, allocator bytes, peak RSS, catalog/view retained size, exact
query counts, candidate visits, and legacy installation counts.

## Verification

Run the focused suites covering environment lookup, declaration headers,
inference, traits, implementations, overloads, UFCS, privacy, and module
binding. Then run:

```bash
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
scripts/test compiler-blorp-sanitize
scripts/test std-check
scripts/test leak
```

Run the public infer/typecheck should-pass and should-fail fixtures for
overloads, UFCS, trait inheritance, private implementations, imported
functions, globals, callbacks, and debug-only calls.

## Acceptance Criteria

Accept only if:

1. all accepted graph declaration categories have one catalog authority;
2. `Env` contains only explicitly documented lexical/body-local state;
3. no production lookup falls back to graph declarations in legacy scope
   symbols;
4. all legacy graph installation counters are zero;
5. exact lookup cost is independent of unrelated graph size;
6. candidate order, diagnostics, visibility, purity, and identity are unchanged;
7. production replay responses are byte-identical;
8. peak RSS does not regress materially; and
9. focused and broad typecheck/ownership gates pass.

## Valid Merge Point

This issue is a valid merge point when all semantic reads use the catalog and
module views, even if dead legacy builders, adapters, counters, and temporary
validation code remain. Correctness must not depend on Issue 23; Issue 23 is a
mandatory cleanup and proof step.
