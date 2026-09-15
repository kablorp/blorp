# Reduce Repeated Core Child Materialization In Perceus

**Status:** Proposed; hardest item, requiring a measured traversal-boundary cut

**Current state:** compiler self-compilation is Core-bound: early Core, late
Core, and Core lowering account for about 61.6% of uninstrumented phase time.
In an exact profile at `f6af78c0`, `stage_09_core/perceus` accumulated
17,607.924 ms self and `stage_09_core/traverse` accumulated 12,567.790 ms self.
The hottest traversal functions were:

- `map_core_expr_children_with_map_context`: 22,454,819 calls and 4,154.039 ms self;
- `immediate_core_expr_children`: 25,510,987 calls and 2,160.985 ms self;
- `map_core_expr_children`: 13,690,526 calls and 1,306.424 ms self; and
- `map_context_type`: 22,762,640 calls and 1,268.209 ms self.

Perceus adds 4,488,817 calls to `summarize_linear_ownership_uses` and 5,191,447
calls to `summarize_call_args`. Inclusive traversal times overlap recursively
and are not additive.
**Next action:** Attribute child-list construction, ownership-summary revisits,
and unchanged-node reconstruction to individual production Perceus operations.
Choose one repeated walk or materialized child-list family and remove it; do not
begin with a universal visitor or ownership-plan redesign.
**Read first:** `blorp/src/compiler/stage_09_core/traverse.brp`,
`blorp/src/compiler/stage_09_core/perceus.brp`,
`blorp/test/compiler/stage_09_core/test_core_traverse.brp`,
`blorp/test/compiler/stage_09_core/test_core_perceus.brp`, the Perceus ownership
roadmap, and Issue 14's general Core-work admission rules.
**Fast loop:** Use the `perceus` mode of
`benchmarks/compiler_core_pipeline_work_profile` plus the direct window of
`benchmarks/compiler_perceus_memory`, varying node count, argument width,
managed-owner density, and branch depth independently.
**Decision:** Admit one consumer-specific cut only after counters identify it.
Ask for guidance before changing `CoreExpr`, traversal APIs used by other
passes, ownership contracts, or the order of `DupExpr`/`DropExpr` insertion.

## Objective

Reduce the number of temporary child lists, repeated ownership-summary visits,
or unchanged Core nodes reconstructed by Perceus while preserving exact
ownership behavior and value semantics.

Possible experiments, in increasing scope, are:

1. add a fold/iteration helper for a specific Perceus query that currently
   allocates `immediate_core_expr_children(expr)` only to consume it once;
2. return an unchanged source node when a named Perceus operation proves that
   no child or ownership field changed;
3. compute one narrowly scoped function-local ownership fact used by two
   measured Perceus consumers, deleting both prior walks; or
4. specialize a traversal callback that currently remaps types or context even
   when the pass does not change them.

Each experiment must delete the path it replaces. Do not add a parallel fact
system, retained universal cache, general pass manager, or heuristic based on
expression spelling or shape.

## Invariants And Tests

- Preserve the exact Core expression variant, type, source location, variable
  identity, evaluation order, and child order.
- Preserve every ownership contract, `DupExpr`, `DropExpr`, borrow boundary,
  reuse witness, COW uniqueness decision, and cancellation owner lifetime.
- Preserve stack-depth behavior for deeply nested expressions; a recursive
  convenience helper must not replace an iterative/frame-safe path.
- Preserve generic/monomorphic and ordinary/managed behavior.
- Cover leaves, unary and wide children, lets, calls, lambdas, matches, loops,
  closures, borrowed temporaries, aggregates, cancellation-sensitive owners,
  and deliberately changed versus unchanged children.
- Require exact post-Perceus Core, ownership-event, ARC-balance, and generated-C
  comparisons.

## Measurement

First add counters at the actual traversal boundary for child lists requested,
child elements produced, callbacks invoked, ownership-summary node visits,
nodes reconstructed, unchanged nodes reused, and context/type remaps. Separate
these deterministic counters from allocation and timing runs.

```bash
for nodes in 16 32 64 128 256; do
  benchmarks/compiler_core_pipeline_work_profile \
    1 perceus 64 "$nodes" 32 8 64 4 0 0
done

benchmarks/compiler_perceus_memory --measurement-window perceus-direct
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_traverse.brp
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_perceus.brp
```

For a candidate, use narrow exact selectors for the changed traversal and
Perceus functions, then alternate matched baseline/candidate binaries with
`benchmarks/compiler_pass_compare`. Record output checksums, allocations,
releases, retired instructions, peak memory, and latency. Finally compile
`blorp/src/main.brp` through C emission and compare post-Perceus Core plus C
byte-for-byte.

## Acceptance And Rejection

Accept the first cut only when its targeted lists, visits, or reconstructions
fall by at least 25%, direct Perceus retired instructions or allocations improve
by at least 10% on a compiler-shaped workload, leaf/small and ownership-heavy
controls stay within 3%, stack depth does not regress, and every Core/C and
ownership check matches. Reject a broad abstraction without two measured
consumers, a change that merely moves traversal into fact construction, a
synthetic-only win, any lost reuse/cancellation witness, or a cache without an
explicit phase lifetime and invalidation owner.
