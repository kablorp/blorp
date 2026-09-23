# Perceus Cleanup Issues

Perceus is now ten modules under `blorp/src/compiler/stage_09_core/perceus/`
plus a 661-line `perceus.brp` holding the per-declaration pipeline (split
landed 2026-09-22 with byte-identical C). This document turns the
observations made during that split into worker-ready issues. The strategy,
set by Keith: clearer code and clearer responsibilities first; allocations
are a floor that must not rise; improvements are taken when a clearer
structure exposes them.

Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) first. Its rules apply.
Anchors are against main after the second split commit; grep for names.

## Shared rules for every issue

- **Floor, not target.** Every commit is measured on the frozen self-compile
  with `benchmarks/self_compile_measure --require-identical` against a parent
  taken first. `pass_perceus_complete` and total allocations must not rise;
  a decrease is recorded with the mechanism that caused it. Instructions must
  not rise beyond 0.3%.
- **Identity.** Byte-identical C on the self-compile and the small program
  unless an issue says otherwise. Core is compiled into `bin/blorp`, so the
  bootstrap-built harness observes every change directly.
- **Gates**:
  `bin/blorp test --timeout 600 blorp/test/compiler/stage_09_core/test_core_perceus.brp`
  (364 tests), `python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory`
  (80 tests; it scans source text of `perceus/results_and_loops.brp` for
  named records, so a rename there must repoint it), `make hygiene-check`,
  `scripts/compiler-check --changed`, `scripts/test --serial compiler-blorp
  compiler-tools`, `scripts/test leak`, `scripts/test compiler-core-sanitize`,
  and `scripts/test runtime` when ownership behaviour could change. The
  `BLORP_GATE_RESULT` line is the verdict.
- **Two Blorp facts learned in the split.** There is no re-export: a name
  imported into a module is not visible to that module's importers through
  `Module.name`, so a symbol the benchmark bridge reaches by alias needs a
  wrapper. And a custom record type that crosses the same file boundary in
  both directions of a mutual recursion does not unify (the error is "Match
  branch type mismatch: expected X, got path.X"), which is why the drop
  engine lives with the result and loop families in `results_and_loops.brp`.
- **Attribute before cutting.** The Perceus allocation profile
  (`benchmarks/results/perceus_allocation_attribution_2026-09-22.md`)
  attributed only 5.5% of the pass to public helpers; about 94% is inside
  the drop-insertion walk and unattributed. Issue P0 fixes that first, and
  the allocation-motivated issues below cite it.

## P0. Per-node allocation counters inside the drop engine

**Goal.** Know where the roughly 48M allocations of `pass_perceus_complete`
go, by node kind and by helper, on the real program, with counters that
allocate nothing themselves.

**Model.** The lowering metric (`BLORP_CORE_LOWERING_TYPE_METRICS`, commit
`f7599ff4`): opt-in, C-side counters in `runtime.c`, keyed by identity or
enum ordinal, never by a rendered string, with a check that the phase's
allocation total is the same with the variable set and unset. The lowering
metric's first version rendered a type to JSON per call and inflated the
phase 3.8 times; do not repeat that.

**Where.** `perceus/results_and_loops.brp`: `insert_drops_expr_inner` and
its dispatch helpers (`insert_drops_change_aware_*`, `rewrite_loop_body`,
`inserted_expr`, `rebuild_managed_let`, `plan_managed_let`); the
binding-insertion loop that threads `PerceusInsertBindingFrameStack`; the
`PerceusResolvedValueIndex` updates. Report self and inclusive allocations
per Core node kind and per helper, plus counts of `PerceusInsertedExpr`,
`PerceusManagedLetPlan` and frame constructions. Also run the existing
`perceus_work_*` counters (`perceus/work_counters.brp`, consumed by
`stage_09_core/work_profile.brp`) and report the fallback counts by cause.

**Deliverable.** `benchmarks/results/perceus_engine_attribution_<date>.md`
with the table, the on/off total check, and a go/no-go line for P3, P4 and
P5 (which helpers exceed 5% of the pass). One commit; identical C.

## P1. Borrowed-boundary normalization: facts by borrow, state by value

**Observation.** `BorrowedNormalizationContext`, `BorrowedOwnerRewriteContext`
and `BorrowedResultRewriteContext` (`perceus/borrowed.brp`) bundle
`env: PerceusEnv` and `owners: BorrowedOwnerCatalog`, which never change after
the top-level call builds them, with `shadowed_owner_ids: Dict[Int, Bool]`
and `result_satisfied_owner_ids: Dict[Int, Bool]`, the only fields that
change per node. Every `normalize_borrowed_*` function (about 370 lines of
threading) takes and returns the whole record.

**Change.** Split into a borrowed facts record (`env`, `owners`, region kind)
passed by borrow and a small state record (the two dictionaries) threaded
through `CoreTraverse.map_core_expr_children_with_state` where the walk is
structural, and through explicit recursion only where the arm has real
per-node logic (`normalize_borrowed_child`, `normalize_borrowed_transfer_exprs`
are thin; the retain/materialize decisions are not). Delete the combined
records.

**Acceptance.** Identical C; the row does not rise (the copies of `env` and
`owners` per rebuild should make it fall; report the number); the borrowed
suites and the leak gate. Effect: fewer fields rebuilt per node, and the
function signatures say what varies.

## P2. Contract collection: two flags out of the task stack

**Observation.** `ContractCollectionState` (`perceus/contracts.brp`) carries
`contains_parameter_dup` and `contains_parameter_shadow`, two booleans,
inside a record that is rebuilt on every push of `ContractCollectionStep` /
`ContractCollectionTaskStack` just to flip a flag. The other three fields
genuinely accumulate.

**Change.** Keep the accumulating fields in the state; compute the two flags
by a separate early-exit query (`any_core_expr` over the body, or the same
walk with a local `var` that stops at the first hit) before or after the
collection, so a flag flip no longer rebuilds the state record. Measure how
many pushes the collection performs on the self-compile before deciding
whether the rebuild is worth the change; if it is under 1% of the pass, do
the simplification for clarity only and say so.

**Acceptance.** Identical C; contract suites; the row does not rise.

## P3. The resolved-value index as an id-keyed table

**Observation.** `PerceusResolvedValueIndex` (`perceus/results_and_loops.brp`,
used by `resolved_value_occurrence_count`, `add_resolved_value`,
`add_resolved_value_occurrences`, `without_bound_value`) is a
`Dict[String, Dict[Int, Dict[Int, Int]]]` keyed name, then `uniq`, then
`def_id`, threaded through every recursive call of `insert_drops_expr_inner`
and rebuilt with `.set` at every binding that consumes an occurrence. It is
real state, but its shape is the name-keyed shape the identity roadmap
retires, and the triple nesting allocates on every update.

**Gate to start.** P0 shows the index's updates above 5% of the pass, or
step 1 of [`CORE_ID_MIGRATION.md`](CORE_ID_MIGRATION.md) has landed (then
`uniq` is unique per binder and the name key is redundant).

**Change.** Key by the variable's identity: after roadmap step 1, a flat
`Dict[Int, Int]` from `uniq` to count (or a list indexed by `uniq` within the
function when the range is dense); before it, the same with the pair
encoded as one Int and the name dropped only where `uniq` is already
unique (SSA versions). Delete the String level.

**Acceptance.** Identical C; the row falls by what P0 predicted; the
occurrence-count tests in `test_core_perceus.brp`.

## P4. One frame-stack helper instead of three

**Observation.** Three hand-rolled explicit-stack unions with the same
"frame carries the rest of the stack as its last field" shape:
`PerceusOwnershipSummaryFrameStack` (`perceus/uses.brp`),
`PerceusLambdaNormalizeFrameStack` (`perceus/borrowed.brp`),
`PerceusInsertBindingFrameStack` (`perceus/results_and_loops.brp`). Each is a
manual trampoline for a walk that returns a rebuilt value.

**Change.** One generic frame stack in `traverse.brp` or a small
`stage_09_core/frame_stack.brp` (a list-backed stack of a frame payload
type, with push, pop and top), and the three walks over it. Check first
whether Blorp's generics express the payload cleanly and whether a
list-backed stack allocates less than the union chain (it should: one list
grown in place versus one union node per frame). If it allocates more, stop
and report; the three unions stay.

**Acceptance.** Identical C; the three owning suites; the rows for the
summary walk and the binding insertion do not rise.

## P5. Small shapes in the drop engine

**Observations**, each small on its own; do them in one issue after P0 says
which matter:

- `PerceusInsertedExpr.direct_consume: Option[PerceusDirectConsume]` where
  `PerceusDirectConsume` wraps one `CoreVar`; `Option[CoreVar]` removes one
  indirection per consumed node if nothing else needs the wrapper (check
  its docstring: the record already records a rejected Changed/Unchanged
  union, so read the reasoning before touching the shape).
- `PerceusManagedLetPlan` (ten fields, six of them `CoreExpr`s produced by
  earlier steps of `plan_managed_let`) is built once and consumed by
  `rebuild_managed_let` and `managed_let_reuses_source`; if it is never passed
  further, compute the fields as locals and publish once at the return.
- `exact_owned_vars_add/remove/contains` (`CoreVar` set over a list) and
  `int_list_contains` (`contracts.brp`) are the same membership shape; after
  roadmap step 1 the `CoreVar` version can key on `uniq`.
- `same_core_expr` / `same_core_expr_list` are redeclared in four `perceus/`
  files (eleven files repo-wide) behind a comment that says to delete them
  once the bootstrap pin passes the commit that introduced
  `blorp_same_object`. Check the pin (`blorp/build/bootstrap.env`); if it has
  passed, replace all copies with one `memory: same_object` import in a
  separate, repo-wide commit.

**Acceptance.** Identical C; the row does not rise; report each item's
effect separately.

## P6. Assignment alias normalization: drop the dead-weight environment

**Observation.** `AssignmentAliasNormalizationContext` (`perceus/mutable.brp`,
the `normalize_assignment_alias_*` family, about 600 lines) carries
`env: PerceusEnv` next to `local_aliases` and `exact_owned_vars`, which are
genuine scope state. The environment never changes.

**Change.** Pass `env` by borrow as its own parameter and keep the two
scope fields as the state record. This is the same shape as P1 and can be
done by the same worker after it.

**Acceptance.** Identical C; the mutable suites; the row does not rise.

## Order

P0 first and alone. P1 and P2 are independent of P0 and of each other; P6
follows P1. P3, P4 and P5 wait for P0's table, and P3 prefers roadmap step 1.
Each issue is one squash commit with its measurement in the commit body.
