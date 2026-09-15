# Hoist Record-Field Query Sorting

**Status:** Proposed; correctness-first micro-optimization

**Current state:** `env_find_records_with_fields` sorts the same
`field_names` query while examining candidate record symbols and also sorts
each candidate's fields for comparison.
**Next action:** Add a test with unsorted/duplicate requested fields, hoist the
query normalization before environment traversal, and measure the production
function.
**Read first:** `blorp/src/compiler/stage_06_typecheck/type_system/env.brp` and
`blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp`.
**Fast loop:** `bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp` plus a proposed record-query profile.
**Decision:** Hoist only query-invariant work; do not change record visibility,
scope precedence, or field equality semantics.

## Objective

Sort or otherwise normalize the requested field list once per query instead of
once per candidate record.

## Proposed Shape

```blorp
sorted_query: List[String] = field_names.sort()
for scope in env.scopes:
	for symbol in record_symbols(scope):
		if record_field_names(symbol).sort() == sorted_query:
			result = result.append(symbol)
```

First confirm whether duplicate query fields are meaningful. If equality is
actually set equality, represent that rule explicitly and test it; do not
silently change the current multiset behavior. Candidate field-name caching is
out of scope unless profiling shows its sort dominates after query hoisting.

## Invariants And Tests

- Preserve exact field-name equality, including empty, duplicate, and reordered
  inputs.
- Preserve inner-to-outer scope traversal and result order.
- Preserve alias, visibility, shadowing, and same-name record behavior.
- Do not add a mutable cache to `Env` or key only by display spelling.

## Feedback Loop

Add a proposed fixture varying scopes, record candidates per scope, fields per
record, query width, and match position. Count query sorts, record sorts,
candidate visits, allocations/releases, retired instructions, elapsed time,
and ordered record-identity checksums.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when query sorts equal one per call, wide candidate scans improve
retired instructions or allocations by at least 10%, one-record queries remain
within 2%, and exact results match. Reject if query normalization changes
duplicate semantics or if record-side sorting dominates so completely that
the production improvement is immaterial; record caching would require a new
separately reviewed issue.
