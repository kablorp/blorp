# Batch Cancellation-Plan Child Results

**Status:** Proposed subproblem of Issue 53

**Current state:** `analyze_current_behavior_expr` recursively visits immediate
children and concatenates each child's `sites`, `let_protections`, and
`match_scrutinee_protections` into growing lists. It ran 985,345 times in the
retained self-compile.
**Next action:** Add element-copy/allocation counters around the three
accumulators and try one ownership-local collector without changing planning.
**Read first:** `blorp/src/compiler/stage_10_backend/cancellation_plan.brp`,
`blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`,
[Issue 53](53-minimize-and-compact-cancellation-cleanup.md), and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp` plus the existing cancellation-plan request fixtures.
**Decision:** This issue may change result construction only. Ask for guidance
before changing activation semantics, owner/site numbering, or cleanup ABI.

## Objective

Eliminate repeated copying of child planning results while leaving the
cancellation plan and emitted cleanup behavior unchanged.

## Why

The hot loop has this repeated shape:

```blorp
for child_expr in CoreTraverse.immediate_core_expr_children(expr):
	child_analysis = analyze_current_behavior_expr(...)
	children = children.append(child_analysis.facts)
	sites = sites.concat(child_analysis.sites)
	protections = protections.concat(child_analysis.let_protections)
	match_protections = match_protections.concat(child_analysis.match_scrutinee_protections)
```

`List.concat` allocates a new list and copies both inputs. Repeating it at every
tree edge can recopy previously accumulated subtree results. Some static
child-field terms are aggregate output size, so counters must distinguish
necessary copied elements from repeated prefix copies.

## Proposed slice

Keep recursive analysis and all scalar facts unchanged. Compare:

- appending each returned element into uniquely owned local lists;
- returning chunk lists and flattening once per parent.

Do not repeat Issue 53's broader threaded-accumulator prototype: it produced
neither an allocation nor timing improvement on the retained 10,000-managed-let
request. Any future threaded design needs a materially different workload and
hypothesis before it is admitted here.

Do not retain both the old lists and a new index/builder in production. Avoid a
second expression traversal; Issue 53 explicitly rejects emitter rescans.

Instrument child count, returned elements, copied elements, empty-child skips,
allocations/releases, and the semantic plan checksum. Include leaf-heavy,
deep-unary, wide-branch, managed-match, and cancellation-bearing fixtures.

## Invariants

- Site and owner numbering remain exact and deterministic.
- List order remains preorder-compatible with emitter lookups.
- Maximum live slots and branch cancellation facts are unchanged.
- Duplicate match-scrutinee fallback behavior remains conservative.
- Generated C should be byte-identical for representative fixtures.
- No cancellation, sanitizer, or leak regression is acceptable.

## Acceptance and rejection

Accept if the focused wide/deep fixtures eliminate repeated prefix-copy work,
reduce allocations or retired instructions by at least 10%, and do not regress
the leaf case more than 2%. Require byte-identical generated C, the owning
suite, codegen audit, `scripts/compiler-check --changed`, and the relevant
cancellation sanitizer/leak gates.

Reject if the collector changes semantic planning, adds a traversal, retains
parallel authorities, or improves only unoptimized wall time without a direct
work reduction.
