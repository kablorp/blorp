# Cut Over Exact Callable Identity To The Declaration Catalog

**Status:** Blocked on Issue 38

**Dependencies:** Issue 38

**Parallel work:** Candidate/overload test inventories for Issue 40 may proceed,
but production implementation must integrate serially.

## Objective

Route exact accepted callable lookup through nominal catalog identity and stop
publishing graph-owned callable records into `Env` merely to recover a callable
whose ID is already known.

This issue intentionally separates exact identity from source-name candidate
discovery. Issue 40 owns overload and source-name lookup.

## Scope

Inventory exact lookups for ordinary functions, foreign functions, builtins,
function values/callbacks, debug-only callables, and other non-trait accepted
callables. Trait and implementation method ownership remains in Issue 41 unless
the catalog already represents a method as an ordinary callable with no
additional semantic lookup.

For every consumer, record:

| Consumer | Nominal ID type | Expected kind | Owner validation | Metadata read | Replacement |
| --- | --- | --- | --- | --- | --- |

Separate graph-owned IDs from IDs for genuinely body-local functions. If local
functions still need `function_indexes_by_callable_id`, retain or narrow that
lexical index; remove only graph-owned entries.

## Required Change

1. Add a typed, constant-time catalog query for exact callable identity.
2. Validate callable category and owner at the catalog boundary.
3. Route every in-scope production reader through the catalog query.
4. Preserve function-value and callback identity without reconstructing a
   source-name candidate search.
5. Stop installing in-scope accepted graph callables in the exact-ID `Env`
   index.
6. Delete graph-only exact callable helpers and adapters. Narrow any surviving
   index and name it as lexical/local responsibility.

Wrong-kind or wrong-owner IDs must fail closed. Do not choose an entry merely
because its integer ID exists in another catalog category.

## Non-Goals

- Do not migrate source-name candidate discovery or overload selection.
- Do not change lexical function shadowing.
- Do not migrate trait/implementation lookup or UFCS.
- Do not redesign callable IDs.
- Do not remove a local-function index that still has a lexical use.

## TDD And Structural Proof

Cover exact lookup for ordinary, foreign, builtin, debug-only, callback, and
function-value paths. Add negative cases for wrong category, wrong graph,
wrong owner, missing ID, and rejected declaration.

Require:

```text
exact_graph_callable_catalog_queries > 0
exact_graph_callable_env_queries == 0
exact_callable_query_graph_scans == 0
legacy_exact_graph_callable_installs == 0
```

Adding unrelated modules or same-name overloads must not increase candidates
visited by exact lookup.

## Acceptance Criteria

- Exact graph callable lookup is a typed catalog operation.
- No in-scope graph callable is published to `Env` solely for exact lookup.
- Function-value and callback behavior is unchanged.
- Any surviving exact callable index has a documented lexical-only owner.
- Wrong-kind and provenance failures are tested.
- No dual read or compatibility adapter remains.
- Focused callable and Stage 06 checks pass without clear latency regression.
- Recoverable graph behavior and failed-module exclusion remain unchanged.
- `docs/ARCHITECTURE.md` describes catalog-owned exact graph callables in this
  same merge.

## Verification

Run exact callable, foreign, builtin, callback/function-value, debug-only, and
prepared-module fixtures, then `scripts/compiler-check --changed` and the
affected Stage 06 manifest/tests. Inspect catalog query counters and confirm the
work is independent of unrelated graph size.
