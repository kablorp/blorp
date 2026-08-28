# Cut Over Values, Traits, And Implementations To The Declaration Catalog

**Status:** Ready after Issue 21

## Context And Dependencies

Issue 21 establishes the catalog and module view as the sole authority for
graph-owned types and constructors. This issue migrates the remaining accepted
declaration categories: functions, globals, overloads, traits,
implementations, implementation methods, and UFCS candidates.

This is the final semantic cutover. At completion, `Env` remains responsible
for lexical body state, not for storing a module graph's accepted declarations.
Issue 23 then removes remaining legacy construction code and performs final
measurement.

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
