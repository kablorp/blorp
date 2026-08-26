# Add A Direct Scope Lookup Index

**Status:** Ready for implementation after confirming Issue 02 overlap

## Issue Summary

Avoid allocating and traversing `List[Int]` just to obtain the newest symbol for
a name. Add a direct latest-symbol index to `Scope` while retaining the complete
same-name index for overload and diagnostic queries.

This issue optimizes lookup. Issue 02 optimizes construction. Coordinate the
`Scope` representation edits, but preserve two separate measurements and
commits where possible.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, made 704.1 million
allocations, and reached 2.218 GB peak RSS. External sampling attributed 3,257
samples, 2.166% and about 3.95 seconds, to `env.scope_lookup` and its direct
library/runtime descendants.

The current lookup performs dictionary lookup, `Option.get_or([])`, list index
lookup, another option match, and symbol-list lookup. The complete same-name
list is necessary for some APIs, but ordinary lexical lookup only needs its
first/newest index.

## Current Representation And Ordering

Primary file: `compiler/src/stage_05_types/env.brp`.

`Scope.symbols_by_name` maps a name to indexes ordered newest first.
`scope_add_symbol` creates a new entry with
`[symbol_index].concat(name_candidates)`. `scope_lookup` then retrieves index
zero and reads `scope.symbols[index]`.

Other functions, including `scope_symbols_named`, need the complete list to
support overloads and fallback resolution. Replacing that list with only one
index would be incorrect.

## Goals

1. Resolve ordinary newest-symbol lookup with one dictionary lookup and one
   symbol-list lookup.
2. Preserve complete same-name ordering for aggregate queries.
3. Keep the direct index synchronized at every scope construction boundary.
4. Demonstrate lower call/allocation cost for hit and miss workloads.

## Non-Goals

- Do not remove `symbols_by_name`.
- Do not change lexical/module/import precedence.
- Do not redesign `Env` or inference name resolution.
- Do not add a cache outside `Scope`.
- Do not change function callable-ID indexing.
- Do not merge all indexes into a stringly typed dictionary.

## Proposed Design

Extend `Scope` with:

```blorp
latest_symbol_index_by_name: Dict[String, Int]
```

Update `EMPTY_SCOPE` and every direct `Scope` construction. On insertion, set
the latest index once. Implement lookup as:

```blorp
private pure func scope_lookup(scope: Scope, name: String) -> Option[Symbol]:
	match scope.latest_symbol_index_by_name.get(name):
		Some(index):
			scope.symbols.get(index)
		None:
			None
```

An alternative representation combines latest and all indexes in one record
value. Use it only if measurement shows one dictionary is materially better
and the more complex update does not obscure lookup semantics. The separate
dictionary is the safer initial change.

## Mechanical Implementation Sequence

1. Add direct tests for `scope_lookup` observable behavior through public `Env`
   APIs: hit, miss, repeated name, and nested scopes.
2. Add a benchmark that builds a stable environment once and performs many
   lookup hits/misses without rebuilding it.
3. Add `latest_symbol_index_by_name` to `Scope` and `EMPTY_SCOPE`.
4. Update `scope_add_symbol` or the batch builder from Issue 02 to set it.
5. Search for all direct `Scope` record literals and update them.
6. Change only `scope_lookup` to use the direct index. Keep aggregate APIs on
   `symbols_by_name`.
7. Add a test-only consistency check comparing latest index with index zero of
   the complete list after arbitrary insertion sequences.
8. Measure hit and miss paths separately.

## Invariants And Pitfalls

- The newest same-name symbol is authoritative within a scope.
- Outer scopes are considered only after the current scope misses.
- Same-name aggregate order remains newest to oldest.
- The direct index and complete index must be updated atomically in the returned
  value.
- Empty scopes and popped scopes must not retain stale indexes.
- Batch insertion must set the latest index to the final insertion for each
  name, not the first.
- Do not expose the private index as a public API.
- The extra dictionary consumes memory. Measure peak/index bytes and ensure
  lookup savings justify it.

## Fast Feedback Loop

Use or add a focused environment benchmark with:

```text
symbols: 32, 256, 2,048
distinct-name ratios: 100%, 50%, 10%
lookups: 10,000 or more
hit ratios: 0%, 50%, 100%
scope depths: 1, 8, 32
```

Separate setup time from lookup time. Report hit count, selected symbol-ID
checksum, elapsed microseconds, allocations during lookup, and index memory if
available. The key assertion is zero temporary same-name lists on the ordinary
lookup path.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_env.brp
./blorp test --timeout 180 compiler/tests/test_compiler_infer.brp
scripts/compiler-check --stage types
scripts/compiler-check --stage typecheck
```

Retain public fixtures for lexical shadowing and cross-scope lookup under
`tests/test_compiler/infer/`.

## Acceptance Criteria

- `scope_lookup` no longer calls `get_or([]).get(0)` on the complete-name list.
- The direct and aggregate indexes remain consistent under repeated names,
  batches, and scope push/pop.
- Lookup hit/miss allocations decrease materially; ideally the direct hit path
  allocates no intermediate list.
- Lookup time no longer depends on overload count for the same name.
- The additional index's construction and memory cost are reported.
- All environment, inference, and shadowing tests pass unchanged.

