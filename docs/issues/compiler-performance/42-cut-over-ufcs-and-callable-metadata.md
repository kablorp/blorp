# Cut Over UFCS And Remaining Callable Metadata

**Status:** Blocked on Issue 41

**Dependencies:** Issue 41

**Parallel work:** None for production implementation. This is the final
authority cutover before legacy deletion.

## Objective

Move UFCS candidate construction and every remaining accepted callable metadata
read to the catalog/module-view architecture. At completion, no accepted graph
declaration family may require publication into `Env`.

## Required Inventory

Find all remaining graph declaration reads and writes, including:

- UFCS candidate discovery and order;
- trait and implementation methods eligible for UFCS;
- generic constructor/function UFCS behavior;
- purity and type-parameter constraints;
- foreign ABI facts;
- builtin status;
- debug-only restrictions;
- resource cleanup callables;
- parameter counts and callable shape; and
- any record-field callable discovery that still uses graph symbols.

Produce a table mapping every remaining field/helper to catalog storage,
module-view projection, lexical ownership, or deletion.

## Required Design

- Module views own ordered UFCS candidate IDs.
- Catalog entries own the complete callable/trait/implementation metadata used
  to filter or validate those candidates.
- Preserve module path order, source order, purity, bounds, and ambiguity
  behavior explicitly.
- Avoid copying full overload or method records per query.
- Route all remaining exact metadata reads through typed catalog APIs.
- Delete the corresponding graph writes and reads from `Env` immediately.

Do not make a generic metadata bag or string-keyed escape hatch. If categories
require distinct facts, expose distinct typed queries.

## Non-Goals

- Do not change UFCS syntax or resolution semantics.
- Do not redesign resource, foreign, builtin, or debug behavior.
- Do not optimize lexical scopes.
- Do not perform the final broad dead-code deletion; Issue 43 owns cleanup.
- Do not retain fallbacks for rare callable categories.

## TDD And Structural Proof

Cover:

- UFCS order across local and imported modules;
- generic functions, constructors, trait methods, and implementation methods;
- purity and type-parameter bounds;
- ambiguity and exact diagnostic order;
- private implementation isolation;
- foreign, builtin, debug-only, and resource-cleanup callables;
- wrong-kind metadata queries; and
- stable results with unrelated graph modules.

Require all graph declaration install counters to be zero. The only remaining
`Env` insertions must be explicitly classified as lexical/session state.

## Acceptance Criteria

- UFCS candidates are ordered compact IDs in module views.
- All remaining accepted callable metadata is catalog-owned.
- No accepted graph declaration is published into `Env`.
- All surviving `Env` symbols and indexes have a lexical/session owner.
- UFCS, foreign, builtin, debug, resource, and generic behavior is unchanged.
- No dual authority, compatibility wrapper, or generic metadata escape hatch
  remains.
- Focused tests and `scripts/compiler-check --changed` pass.
- Repeated Phase 01-06 latency shows no material regression and records the
  cumulative improvement since Issue 35.
- Recoverable graph behavior and failed-module exclusion remain unchanged.
- `docs/ARCHITECTURE.md` records the final per-family declaration authority in
  this same merge.

## Verification

Run UFCS, trait/implementation method, generic, purity, foreign, builtin,
debug-only, resource, prepared-module, and frontend benchmark fixtures. Build
once before merge, run affected Stage 06 tests, and record logical counters
plus repeated Phase 01-06 timings.
