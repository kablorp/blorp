# Bound Implementation-Obligation Traversal

**Status:** Accepted narrow refactor; substitution lookup remains separate

**Current state:** `implementation_pattern_matches_with` iterates bound type
parameters and each parameter's trait bounds. The retained profile confirmed
that obligation visits are aggregate-linear in declared obligations, while
`bound.bounds.enumerate()` materialized one indexed collection per visited
bound. The accepted change carries the trait index manually and preserves
short-circuit order and bound identity lookup. Substitution lookup still
performs a linear scan per visited bound; indexing that lookup remains outside
this issue.
**Evidence:** [`benchmarks/results/compiler_implementation_pattern_obligation_traversal_2026-09-15.md`](../../../benchmarks/results/compiler_implementation_pattern_obligation_traversal_2026-09-15.md).
**Next action:** None for the obligation traversal. Open a separate issue if
substitution lookup width becomes production-significant.
**Read first:** `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`,
`blorp/src/compiler/stage_06_typecheck/type_system/accepted_trait_implementation_authority.brp`, `blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_semantic_catalog.brp` plus a proposed bound-width probe.
**Decision:** Close as an analyzer false positive if visits equal necessary
input obligations. Ask for guidance before caching `obligation_satisfied`.

## Objective

Determine whether implementation-obligation matching performs avoidable
super-linear work and optimize only the measured redundant component.

## Question

```blorp
for bound in bounds:
	match impl_subst_lookup(entries, bound.name):
		Some(concrete_type):
			for indexed_trait_name in bound.bounds.enumerate():
				if not obligation_satisfied(...):
					return False
```

Nested syntax is not automatically quadratic: if each inner list belongs to
one outer bound, total visits are `sum(bound.bounds.length())`. Potential
avoidable work instead includes repeated `impl_subst_lookup`, repeated
enumeration allocation, reconstruction of trait obligations, or duplicate
semantic queries.

## Admission experiment

Vary bound-parameter count, traits per parameter, substitution width, hit/miss
position, and duplicate obligations. Record:

```text
pattern_match_requests
bound_parameters_visited
trait_obligations_visited
substitution_entries_compared
obligation_satisfied_calls
enumeration_allocations
semantic_checksum
```

First confirm whether `enumerate()` materializes a collection at this boundary.
If visits are linear in total obligations and no repeated lookup dominates,
record that result and close the issue without a compiler change.

Potential bounded fixes are an indexed substitution lookup or index-free
iteration carrying an integer. Memoizing semantic obligations is outside scope
unless identity, context, and invalidation are explicit.

## Invariants and acceptance

- Bounds and bound identities remain positionally aligned.
- Short-circuit order and first failure are unchanged.
- Missing substitutions retain current behavior.
- `obligation_satisfied` is invoked in the same semantic context.
- Diagnostics and accepted implementation identity remain unchanged.

Accept a refactor only if avoidable work accounts for at least 10% of the
focused window and the candidate reduces it without changing call order or
results. Run the owning typecheck suites and `scripts/compiler-check --stage
typecheck`.

Reject scope expansion into trait caching, accepted-authority redesign, or an
optimization justified only by multiplying outer and child-collection widths.
