# Compiler Speed Roadmap

Goal: compile `blorp/src/main.brp` to C in about 10 seconds on the reference
machine, without lowering the maintainability bar. This document lists the
open compiler-speed work; completed cuts, their measurements and the rejected
experiments are in `benchmarks/results/` and Git history. Per-node cost in the
generated C is in [`PER_NODE_CODEGEN_ROADMAP.md`](PER_NODE_CODEGEN_ROADMAP.md);
the name-to-id and table work that removes string and name work from Core is in
[`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md). The standing outcomes are in
[`COMPILER_PRIORITIES.md`](COMPILER_PRIORITIES.md).

## How To Work An Item

Setup, the fast feedback loop, the measurement protocol, the stage-2 rule and
landing rules are in [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md); the
profiling recipes are in
[`DEVELOPMENT.md`](DEVELOPMENT.md#function-profiling-and-flame-graphs). This
list adds what is specific to speed work:

- Measure with `benchmarks/self_compile_measure` on both `--program self` and
  `--program small`, with `--require-identical` unless the item says the C may
  change. Primary metrics are retired instructions and per-phase allocations;
  wall time is confirmation only, and never read from a run made while another
  gate or build is active on the machine. Iterate at `-O0`; confirm at `-O2`.
- `bin/blorp compile --dump-core-after=<stage> --dump-core-file=<path>` gives a
  Core snapshot before and after a pass; diff two snapshots to localize a
  semantic change. `--check-invariants` runs the full invariant set.
- **Reading profiles.** A module-limited exact profile charges uninstrumented
  callee time to the instrumented caller's self row, so a function's share in
  such a profile is an upper bound on what removing its own work can win, and
  in practice the win has been an order of magnitude smaller (a 13.5% share
  bought 0.8% of instructions). Size an item from allocation counters or a
  whole-compiler profile before promising a number. Single-sample instruction
  readings under load vary by about half a percent; accept or reject only on
  two or three samples.
- One change per commit, named after the cut, with a protecting test first.
  Use grouped arm functions rather than one giant match when adding locals to
  an 89-arm match (a larger one overflowed the default 8 MB stack at -O0).
  Delete the code a change replaces; no parallel authorities, no caches without
  a lifetime, no heuristics keyed on names.
- On per-node hot paths prefer a direct loop over an explicit worklist to a
  visitor that takes a closure: a closure-typed `step` parameter is an
  indirect call per child that the backend cannot inline, and a fold of that
  shape cost 6% instructions despite flat allocations.
- Build immutable facts, then consume them: a pass builds its result inside one
  function that owns local `var` accumulators, publishes one immutable
  product, and never updates it again. Do not thread a `State` record through
  recursion and rebuild it per node. Allocation is a small part of a pass's
  cost; further state-record-to-builder conversions are not a lever by
  themselves.

## Open Items

### P2. Gate production invariant walks

The early-Core resolve and std-inline invariants are one fused walk
(`check_resolve_and_std_inline_invariants` in `early_invariants.brp`) that runs
on every compile at `tuple_flatten`, the last early pass, even without
`--check-invariants` (`early_pipeline.brp`, `resolve_and_std_inline_invariant`).
That is still a full read walk of the program per compile.

**Change.** Move the walk under `--check-invariants`, keeping only fast
identity checks (`check_definition_id_uniqueness`, milliseconds) in
production. If the walk protects a real production failure mode, replace it
with a fact recorded by the pass that established it (for example the resolve
pass returning a `CoreResolvedProgram` opaque type that later passes require,
so "unresolved survived" is a type error rather than a walk).

**Acceptance.** Identical C; `--check-invariants` still runs all walks; early
Core instructions down by the measured walk cost; Core suites green.

### B2. Cancellation forced re-analysis

`analyze_current_behavior_expr` in `cancellation_plan.brp` runs a second,
fail-closed pass over the function body whenever
`ambiguous_match_scrutinees` finds duplicate exact variables
(`forced_match_scrutinees`). The second pass was measured at about 3% excess
node visits, one function contributing 85%; that count has not been
re-measured on the current compiler.

**Change.** Cache the first analysis result for the forced scrutinee subtree
inside the plan builder (lifetime: one function's plan) so the second pass
reads it rather than re-walking. No protection decision changes.

**Acceptance.** Identical C; visit count equals node count within 0.1%;
cancellation suite green. Small; do it only when someone is already in the
file.

### W1. Late-Core walk fusion

`resolve_callables`, `backend_projection` and `match_projection` are fused into
one bottom-up walk, and `tensor_specialize` is folded into `specialize`
(`fused_late_core_passes` beside `late_core_passes` in
`stage_09_core/pipeline.brp`, selected by `late_core_passes_for_control` when no
observe or stop-after request names a pass in a fused span; the standalone
passes stay for the debug paths).

**Change.** Census, then fuse the remaining separate rebuild walks that are
pure per-node rewrites: `consume_specialize`, `dce` pruning, `record_update`,
`static_string_literals`, `resource_management`, `fairness`, `prepare`; and
the read-only analyses (DCE reachability facts, cancellation analysis,
production invariants) into one read pass. Before pairing two passes check
that neither recurses conditionally (`closure.brp`'s `adapt_function_refs`
skips callee recursion for direct call kinds and mints hoisted declarations, so
a uniform fused walk would change behavior) and that neither mints
declarations. Each fusion keeps the per-pass rows meaningful by naming the
fused pass.

**Acceptance.** Identical C; per-pass rows still meaningful; the dependency
tests compile a program both ways and compare Core JSON; instructions and
allocations down by the measured pass-walk cost.

### G4. Scalar-payload union variants

Fieldless union variants, including `None`, are immortal static singletons.
Every other constructor heap-allocates, including variants whose payload is a
single scalar and Core's leaf node kinds. This is a representation decision for
all unions; measure on Core node counts as well as tokens before proposing a
layout. Earlier struct-payload experiments are
[archived](STRUCT_PAYLOAD_ROADMAP.md); this item is scalar payloads. Not
re-verified against the current backend.

### Smaller open leads

Each is a lead to size with a counter or profile before it becomes an item.

- **Per-node child lists.** `immediate_core_expr_children` (`traverse.brp`)
  returns a fresh `List[CoreExpr]` per visited node, and the read-only walkers
  that call it (referenced from about 90 files) allocate one list per node. Replacing it
  with a direct loop per caller is the cure; a closure-taking fold is not (see
  the visitor rule above). Verified still true in the source; its share of any
  pass has not been measured.
- **Analysis indexes rebuilt per pass.** `flatten_tuples_program` and
  `lower_tailrec_program` each call `build_layout_type_index` on the whole
  program every run (as do `collection_policy.brp` and `specialize_layout.brp`).
  Verified in the source; unmeasured.
- **Trait candidates for DCE.** Early DCE fails closed (`UserCall` without a
  definition id, deferred trait calls) rather than asking trait resolution for the
  candidate targets of a `(trait, method)`; five `Integer` bitwise trait methods
  had no `ImplDecl` and resolved to native operations when this was measured, which
  made the pre-desugar prune fail closed on the self-compile. The code shape
  remains; the self-compile behavior has not been re-measured.
- **Cross-module function references as values.** Passing a qualified
  cross-module function (`Mod.func`) as a callback argument to a generic function
  made the backend emit `#error "Blorp backend could not emit function body"` for
  the caller, with no diagnostic; same-module and unqualified imports work. Seen on
  2026-09-22 and not re-checked; it needs a regression test first.

## Deferred

- **Parallel passes.** The runtime scales to 8 threads on pure CPU work, but
  the one experiment doubled CPU time even single-threaded; understand the
  cross-thread reference-counting cost before retrying. Do not parallelize
  Perceus or the late Core passes in the meantime.
- **Incremental compilation.** Per-module reuse of accepted frontend facts
  keyed by content hash is the next step after the from-scratch compile is near
  10 s; the typecheck's reachable-body order is its first ingredient.
