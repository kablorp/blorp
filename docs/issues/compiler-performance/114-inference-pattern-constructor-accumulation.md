# Index Inference Pattern-Constructor Coverage

**Status:** Proposed; implementation and measurement ready

**Current state:** `typed_pattern_constructor_names` recursively deduplicates
each `TypedOrPattern`, and `match_case_constructor_names` deduplicates those
results again across cases.
**Next action:** Add nested-payload and exact missing-diagnostic tests, then
collect outer constructor coverage into one dictionary spanning options and
cases.
**Read first:** `blorp/src/compiler/stage_06_typecheck/infer.brp`,
`blorp/test/compiler/stage_06_typecheck/test_infer.brp`, and the accepted
[match-bound result](../../../benchmarks/results/compiler_match_bound_names_deduplication_2026-09-15.md).
**Fast loop:** `bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp` plus a proposed exhaustiveness-name profile.
**Decision:** Missing-case diagnostics follow union declaration order, not
discovery order. Use the dictionary only for membership and never reconstruct
diagnostics by iterating it.

## Objective

Remove nested list construction and repeated deduplication while collecting
outer-constructor coverage from typed match patterns.

## Proposed Shape

```blorp
private pure func admit_typed_pattern_constructor_names(
	seen: Dict[String, Bool],
	pattern: TypedPattern,
) -> Dict[String, Bool]:
	match pattern:
		TypedConstructorPattern(name, ...): seen.set(name.text, True)
		TypedOrPattern(options, _):
			var result = seen
			for option in options:
				result = admit_typed_pattern_constructor_names(result, option)
			result
		_: seen
```

Seed once before the case loop, and change `missing_constructor_names` to query
that membership while retaining its `all_names` traversal. Prefer one owning
iterative frame with a pattern worklist; recursive dictionary-by-value state
threading is only a sketch and must be rejected if generated C or clone counters
show COW copies. Do not descend into constructor payload patterns:
`Some(Left(x))` contributes `Some`, not `Left`. The dictionary is
invocation-local and must not become a parallel retained authority.

## Invariants And Tests

- Visit cases and `or` options in their existing order, but use the result only
  for membership.
- Preserve qualified/unqualified constructor spelling behavior.
- Duplicate alternatives and duplicate cases remain one coverage name.
- Non-constructor patterns remain absent, and nested constructor payloads are
  not traversed.
- Missing-constructor diagnostic text and order remain byte-identical.
- Cover nested `or`, mixed qualified patterns, all duplicates, and wide misses.

## Feedback Loop

The proposed profile should call production match exhaustiveness logic with
case count, options per `or`, unique constructor count, and duplicate stride
as independent controls. Record pattern visits, admission comparisons,
accepted names, allocations/releases, retired instructions, elapsed time, and
ordered diagnostic/name checksums.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept if every case and `or` option is visited once, result-list membership
scans disappear without new dictionary clone traffic, the duplicate-heavy
wide fixture improves instructions or allocations by at least 10%, a normal
two-to-four-variant control remains within 3%, and all inferred output and
diagnostics match. Reject if normal matches regress, nested payload
constructors are included, dictionary order becomes observable, or only a
duplicate model rather than production exhaustiveness is measured.
