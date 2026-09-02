# Cut Over Source Callable Candidates And Overloads

**Status:** Blocked on Issue 39

**Dependencies:** Issue 39

**Parallel work:** Trait/implementation and UFCS inventories may proceed, but
the production cutovers must integrate after this issue.

## Objective

Make module views the sole authority for visible accepted callable candidate
IDs and the catalog the sole authority for their full declaration records.
Remove graph-owned source callable and overload entries from `Env` while
preserving lexical precedence and deterministic overload behavior.

## Required Inventory

Locate every production path for:

- unqualified, selective, aliased, and qualified callable lookup;
- local versus imported callable precedence;
- overload ordering and tie-breaking;
- pure/impure filtering;
- generic bounds and inferred type arguments;
- constructor/callable coexistence;
- ambiguity and duplicate import diagnostics; and
- selected overload identity used by later checking.

For each path, distinguish lexical functions from accepted graph callables.

## Required Design

- Module views store compact, deterministically ordered callable IDs per visible
  source name and qualification path.
- The catalog resolves each ID to the complete accepted callable entry.
- Lexical lookup runs first according to existing shadowing rules, then asks
  the module view for graph candidates.
- Candidate APIs retain distinctions needed for purity, generic applicability,
  and source/owner diagnostics; do not flatten them into strings.
- Preserve current source order and tie-breaking explicitly. Do not depend on
  incidental dictionary iteration.

After cutover, delete graph callable/overload source-name publication, reads,
and adapters from `Env`. Lexical functions and genuinely local overload facts
remain session-owned.

## Non-Goals

- Do not migrate traits, implementations, or UFCS.
- Do not change overload resolution semantics or improve diagnostics.
- Do not combine candidate lookup with applicability inference in a new cache.
- Do not retain legacy candidate reads for comparison.
- Do not move lexical functions into module views.

## TDD And Structural Proof

Test:

- local function shadowing under current rules;
- direct, selective, aliased, and qualified imports;
- same-name overload ordering and deterministic selection;
- pure and impure overload separation;
- generic bounds and inferred type arguments;
- callable versus constructor ambiguity behavior;
- duplicate imports and exact diagnostic order;
- rejected/partial headers never entering candidate lists; and
- stable candidate order when unrelated modules are added.

Require:

```text
module_view_callable_candidate_entries == visible_graph_callable_edges
legacy_graph_callable_name_installs == 0
legacy_graph_overload_installs == 0
callable_candidate_full_record_copies == 0
```

## Acceptance Criteria

- Module views contain ordered graph callable IDs, not copied callable records.
- Catalog queries supply complete accepted callable entries.
- `Env` retains only lexical callable/name state.
- Overload choice, purity filtering, generic behavior, and diagnostics are
  unchanged.
- No candidate fallback or dual authority remains.
- Logical work scales with actual visible candidate edges, not the full graph
  declaration closure per body.
- Focused tests and `scripts/compiler-check --changed` pass.
- Recoverable graph behavior and failed-module exclusion remain unchanged.
- `docs/ARCHITECTURE.md` describes catalog/view-owned graph callable candidates
  and overloads in this same merge.

## Verification

Run callable/overload/import/generic/purity fixtures and the dense frontend
benchmark with multiple bodies. Inspect candidate order and selected nominal
IDs, not only pass/fail. Build once before merge and run affected Stage 06
checks.
