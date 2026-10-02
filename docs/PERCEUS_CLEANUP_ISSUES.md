# Perceus Cleanup Issues

Perceus is split into modules under `blorp/src/compiler/stage_09_core/perceus/`
plus a per-declaration pipeline in `perceus.brp`. This document holds the
worker-ready cleanups still open from the observations made during that split.
The strategy: clearer code and clearer responsibilities first; allocations are
a floor that must not rise; improvements are taken when a clearer structure
exposes them. The completed cleanups (the per-node allocation counters, the
borrowed-boundary context split, the contract-collection flag queries, the
one-field direct-consume wrapper) and the rejected one (moving `env` out of
the assignment-alias context, whose reasoning is in the docstring of
`AssignmentAliasNormalizationContext` in `perceus/mutable.brp`) are in Git
history; the allocation attribution is in
`benchmarks/results/perceus_allocation_attribution_2026-09-22.md` and
`perceus_engine_attribution_2026-09-22.md`.

Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first. Its rules apply.

## Shared rules for every issue

- **Floor, not target.** Every commit is measured on the frozen self-compile
  with `benchmarks/self_compile_measure --require-identical` against a parent
  taken first. `pass_perceus_complete` and total allocations must not rise; a
  decrease is recorded with the mechanism that caused it. Instructions must not
  rise beyond 0.3%.
- **Identity.** Byte-identical C on the self-compile and the small program
  unless an issue says otherwise. Core is compiled into `bin/blorp`, so the
  bootstrap-built harness observes every change directly.
- **Gates**:
  `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp`,
  `make hygiene-check`, `scripts/compiler-check --changed`,
  `scripts/test --serial compiler-blorp compiler-tools`, `scripts/test leak`,
  `scripts/test compiler-core-sanitize`, and `scripts/test runtime` when
  ownership behaviour could change. The `BLORP_GATE_RESULT` line is the
  verdict.
- **Two Blorp facts learned in the split.** There is no re-export: a name
  imported into a module is not visible to that module's importers through
  `Module.name`, so a symbol the benchmark bridge reaches by alias needs a
  wrapper. And a custom record type that crosses the same file boundary in
  both directions of a mutual recursion does not unify (the error is "Match
  branch type mismatch: expected X, got path.X"), which is why the drop engine
  lives with the result and loop families in `perceus/results_and_loops.brp`.
- **Attribute before cutting.** About 94% of the pass's allocations are inside
  the drop-insertion walk, not in public helpers; size an issue from the
  counters (`BLORP_PERCEUS_ENGINE_METRICS`, `perceus/work_counters.brp`,
  consumed by `stage_09_core/work_profile.brp`) before promising a number.

## P3. The resolved-value index keyed by exact value identity

`PerceusResolvedValueIndex` is `Dict[Int, Dict[Int, Int]]`, keyed by the
transitional `(CoreVar.id, def_id)` pair; its collision fixtures prove that
neither component is sufficient alone. Do not flatten it to raw `id` or invent
an integer pair encoding while match and synthetic binder identities are
incomplete.

The remaining change belongs to the identity roadmap
([`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md), "Late-Core consumers by exact
id"): once every binder has a strict value id, key the index by that typed
identity; the physical table (dictionary, nested owner and ordinal rows, or a
dense per-owner list) is chosen by a representation probe, and source spelling
never returns to the key. Acceptance: identical C, the three collision and
occurrence-count fixture families in `test_core_perceus.brp`, and no increase in
the Perceus row. If the engine counters do not show enough index work to
support a performance claim, land it as a semantic cleanup with no speed claim.

## P4. One frame-stack helper instead of three

Three hand-rolled explicit-stack unions share the shape "the frame carries the
rest of the stack as its last field": `PerceusOwnershipSummaryFrameStack`
(`perceus/uses.brp`), `PerceusLambdaNormalizeFrameStack`
(`perceus/borrowed.brp`) and `PerceusInsertBindingFrameStack`
(`perceus/results_and_loops.brp`). Each is a manual trampoline for a walk that
returns a rebuilt value.

**Change.** One generic frame stack in `traverse.brp` or a small
`stage_09_core/frame_stack.brp` (a list-backed stack of a frame payload type,
with push, pop and top), and the three walks over it. Check first whether
Blorp's generics express the payload cleanly and whether a list-backed stack
allocates less than the union chain (one list grown in place against one union
node per frame). If it allocates more, stop and report; the three unions stay.

**Acceptance.** Identical C; the three owning suites; the rows for the summary
walk and the binding insertion do not rise.

## P5. Small shapes in the drop engine

Each is small on its own; report each item's effect separately and do them in
one issue once the counters say which matter.

- `PerceusManagedLetPlan` (ten fields, six of them `CoreExpr`s produced by
  earlier steps of `plan_managed_let`) is built once and consumed by
  `rebuild_managed_let` and `managed_let_reuses_source`; if it is never passed
  further, compute the fields as locals and publish once at the return.
- `exact_owned_vars_add`, `exact_owned_vars_remove` and `exact_owned_vars_contains`
  (a `CoreVar` set over a list) and `int_list_contains` (defined in `ownership_contracts.brp`, `perceus/results_and_loops.brp`
  and `perceus/short_circuit.brp`) are the same membership shape; once value ids are strict (see P3) the
  `CoreVar` version keys on the exact id, never on raw `id`.
- `same_core_expr` and `same_core_type` are redeclared as private
  `blorp_same_object` foreign functions in a dozen Core and lowering files
  (`traverse.brp` holds the public one) behind a comment that says to delete
  them once the bootstrap pin passes the commit that introduced
  `blorp_same_object`. The current pin (`blorp/build/bootstrap.env`) contains
  that commit, so replace every copy with one `memory: same_object` import in a
  separate, repo-wide commit, and update the stale comment's pin name with it.

**Acceptance.** Identical C; the row does not rise.

## Order

P4 and P5 are independent of each other. P3's exact-id conversion and the
`CoreVar` half of P5 wait for the identity roadmap's strict value ids. Each
issue is one squash commit with its measurement in the commit body.
