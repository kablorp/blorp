# Deduplicate Match-Bound Names Once

**Status:** Proposed

**Current state:** `rewrite_raw_match_case` computes
`bound.concat(core_pattern_bound_names(pattern)).unique()` before rewriting the
case body. It ran 87,211 times in the retained self-compile, and `List.unique`
is quadratic.
**Next action:** Prove the incoming `bound` uniqueness invariant, add ordering
tests, and replace whole-list deduplication with incremental admission.
**Read first:** `blorp/src/compiler/stage_08_core_lower/flatten.brp`,
`blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp`, the existing
`bound_with_var` helpers, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp` with before/after Core dumps.
**Decision:** This issue changes bound-name construction only; callable/global
rewrite lookup is out of scope.

## Objective

Preserve the ordered unique bound-name result without running quadratic
whole-list deduplication for every raw match case.

## Why and likely implementation

```blorp
bound
	.concat(CoreTraverse.core_pattern_bound_names(match_case.pattern))
	.unique()
```

The desired order is existing bound names followed by each new pattern name's
first occurrence. Reuse or add a narrow `bound_with_names` helper that threads
`bound_with_var`-equivalent admission over pattern names. If measurements show
large bound sets, give the helper a private membership companion; do not
reconstruct output from unordered storage.

Before editing, establish whether every producer already maintains unique
`bound`. If not, the helper must preserve today's normalization of duplicates
in the incoming list, or that invariant must be made explicit and tested at
construction boundaries.

## Measurement and tests

Vary incoming bound width, pattern binder count, duplicates within the pattern,
collisions with incoming names, and nested raw matches. Record names visited,
equality comparisons, list elements copied, allocations/releases, and the
ordered bound/checksum passed to `rewrite_expr`.

Tests must cover no binders, all-new binders, duplicate pattern names, collision
with an outer name, multiple nested cases, and distinct `CoreVar`s sharing a
source name where name-based binding is intentional.

## Acceptance and rejection

Accept if full-list `unique` disappears, exact bound order and rewritten Core
match, and the duplicate-heavy fixture reduces instructions or allocations by
at least 10% without a material small-case regression. Run the flatten suite,
`scripts/compiler-check --changed`, Core invariants, and generated-C inspection.

Reject if the new helper changes shadowing, assumes an unproved incoming
invariant, or introduces a broad bound-environment redesign.
