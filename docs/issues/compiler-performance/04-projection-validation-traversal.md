# Remove C-Symbol Projection Validation Traversal Churn

**Status:** Ready for a bounded first implementation

## Issue Summary

Make C-symbol projection validation traverse Core expressions without repeated
pending-list concatenation, then determine whether validation can be fused with
projection so the backend does not walk the entire Core tree twice.

The first mergeable step is an ownership-friendly worklist with identical
error ordering. Fusion is optional and should be a separate commit if it makes
the change difficult to review.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, made 704.1 million
allocations, and reached 2.218 GB peak RSS. External sampling attributed 7,084
samples, 4.712% and about 8.59 seconds, to
`c_symbol_projection.validate_expr_projection` and its descendants.
`validate_program_projection` / `validate_expr_projection` appeared in 4.77%
of inclusive samples.

The backend performs another projection/emission traversal after validation.
The measured ceiling therefore contains both expression checks and worklist
management, while the architectural opportunity is to avoid duplicate tree
walking entirely.

## Current Code And Cause

Primary file: `compiler/src/stage_10_backend/c_symbol_projection.brp`.

`validate_expr_projection` initializes `pending = [root]`, tracks an index, and
for each expression executes:

```blorp
pending = pending.concat(projection_validation_children(expr))
```

The list keeps all already-visited entries until traversal completes and is
replaced on every node that has children. This creates list copying and ARC
churn. Validation then returns only the first `CSymbolProjectionError`.

`projection_validation_children` intentionally treats a `ClosureCall`
differently: its callee expression must be visited in addition to arguments.
Other calls visit only arguments, while remaining expressions use
`CoreTraverse.immediate_core_expr_children`.

## Problem Statement

The backend pays for:

1. a complete fail-closed validation traversal;
2. repeated persistent list concatenation during that traversal; and
3. a later traversal to actually rewrite/project the validated expressions.

The current first-error behavior is valuable and must not be weakened. The
optimization must remove traversal overhead without turning projection errors
into unchecked assumptions or emission-time crashes.

## Goals

1. Remove repeated concatenation and retention of visited expressions.
2. Preserve exact deterministic first-error selection.
3. Measure node visits, allocations, and elapsed time on broad and deep trees.
4. If cleanly possible, combine validation with projection so each expression
   is semantically examined once.

## Non-Goals

- Do not weaken fail-closed C-symbol projection.
- Do not move semantic typechecking into the backend.
- Do not change compact C-symbol syntax or identity assignment.
- Do not reorder declarations or diagnostics.
- Do not use recursion that can overflow on deeply nested generated Core.
- Do not fuse validation and emission in one unreviewable rewrite.

## Proposed Design: Step A

Replace the growing indexed list with an explicit consuming worklist. Viable
forms are:

- a `Deque[CoreExpr]` when available without adding another expensive copy;
- a list used as a LIFO stack with COW-consuming append/pop operations; or
- stack frames containing `(children, next_index)` so child lists are not
  concatenated into one global list.

Traversal order must match the existing breadth-first/indexed-list order if
that order determines which malformed expression is reported first. Before
choosing a stack, add a test with two distinct errors in different branches and
assert the existing selected error. If order is part of the contract, preserve
it with a queue. Do not silently switch to depth-first order.

## Proposed Design: Step B

After Step A is measured and merged, consider a checked projection result:

```blorp
union ProjectExprResult:
	ProjectedExpr(CoreExpr)
	ProjectionFailed(CSymbolProjectionError)
```

Each projection function validates the identity-bearing operation at the point
it rewrites it. Parent projection propagates the first child failure. This can
remove the separate validation traversal, but only if every expression variant
is covered and the first-error ordering remains explicit.

Do not let the emitter receive a partially projected program. The public
boundary should still return one complete projected program or one typed
error.

## Mechanical Implementation Sequence

1. Add a regression with two errors that records current first-error ordering.
2. Add a focused synthetic-tree benchmark and a node-visit counter.
3. Implement the non-concatenating traversal without changing
   `expr_projection_error` or projection itself.
4. Verify visit count equals reachable expression count and no visited prefix
   is retained unnecessarily.
5. Measure broad and deep tree fixtures.
6. Run all C-symbol projection tests and codegen audit.
7. Inspect whether the remaining profile is dominated by actual checks. Only
   then decide whether Step B is justified.
8. If implementing fusion, add exhaustiveness tests for every expression kind
   that can contain a callable/callback and remove the old traversal only after
   equivalence tests pass.

## Required Error Coverage

Preserve fail-closed behavior for:

- missing callable projection;
- unprojected callable values;
- closure calls whose callee expression is malformed;
- dangling, ambiguous, wrong-category, or noncanonical callable identities;
- callback-bearing list-to-string and custom hash/equality operations;
- detach and concurrent task closures; and
- malformed global initializers as well as function bodies.

## Fast Feedback Loop

Use the existing harness:

```bash
benchmarks/compiler_c_symbol_projection_profile calls 20 512 96 1
benchmarks/compiler_c_symbol_projection_profile fragmented 20 512 96 1
```

The existing arguments are mode, iterations, callables, requested name length,
and calls per function. Extend the fixture or add a focused mode that generates:

- a wide tree with 16/64/256/1,024 sibling expressions;
- a deep tree with the same node counts;
- closure calls with explicit callee children; and
- one early and one late projection error.

Report node visits, worklist operations, elapsed microseconds, allocations,
workload checksum, and selected error. Measure Step A before considering Step B.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_c_symbol_projection.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_backend_projection.brp
./blorp test --timeout 180 compiler/tests/test_compiler_core_emit.brp
scripts/compiler-check --stage backend
tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
```

If generated C changes, compile it with the configured C compiler and inspect
the relevant call/callback symbols. A changed diagnostic order requires an
explicit design decision, not a fixture update.

## Acceptance Criteria

- The traversal no longer executes `pending = pending.concat(...)` per node.
- Every reachable expression is visited once on successful validation.
- First-error selection is unchanged and covered by a multi-error test.
- Wide and deep focused workloads materially reduce allocations and elapsed
  time without stack growth.
- All backend projection, emission, and codegen audit tests pass.
- If validation is fused with projection, the old full-tree traversal is
  deleted and the checked projection boundary remains fail closed.
- Before/after whole-compiler backend time and allocation counts are reported.
