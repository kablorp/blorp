# Generalize Mixed-Symbol Scope Batching

**Status:** Implemented as a minimal mixed-scope substrate

## Context And Dependencies

This issue extends the successful type-and-constructor batch from
[`02-batch-scope-symbol-construction.md`](02-batch-scope-symbol-construction.md).
It depends on Issue 15 for a current baseline and supplies the low-level commit
boundary used by Issues 17 and 18.

The existing private batch handles a type symbol followed by constructor
symbols. It deliberately does not support functions, so it does not update
`function_indexes_by_callable_id`. The next step is to support an ordered mixed
symbol list without changing public `Env` APIs or lookup semantics.

## Problem Statement

`scope_add_symbol` publishes a new symbol list, name dictionary, optional
callable-ID dictionary, `Scope`, and often `Env.scopes` for every symbol. A
caller that already owns an atomic declaration group cannot express one
publication.

The existing specialized batch proves that local accumulators materially
reduce allocations, but generalizing it carelessly could change:

- newest-first same-name history;
- insertion-order iteration;
- duplicate callable-ID behavior;
- type-containment invalidation;
- scope restoration; or
- ownership and COW behavior.

## Goal

Replace the type-only private batch substrate with one private mixed-symbol
batch operation. Continue using it in the existing type-and-constructor
production path so the issue has an immediate production consumer. Do not yet
batch callable-header registration.

## Required API Shape

Use the surrounding naming conventions, but the private scope boundary should be
equivalent to:

```blorp
private pure func scope_add_symbols(
	scope: Scope,
	added_symbols: List[Symbol],
) -> Scope:
	...
```

Issue 16 does not add `env_add_symbols_with_invalidation` or an invalidation
enum. The two existing ordinary and accepted type-declaration Env helpers retain
their explicit containment updates and both call the private scope batch. A
separate Env publication abstraction would be speculative until a later issue
has a production mixed-callable consumer and measurement proves the
consolidation removes meaningful repeated work.

Keep these APIs private. Public callers should continue through semantic
operations such as `env_add_type`, `env_add_func_with_info`, and accepted-header
registration.

## Required Algorithm

1. Return the original scope for an empty batch.
2. Compute the final symbol-list capacity and append/concatenate the ordered
   batch once.
3. Thread one local `symbols_by_name` accumulator.
4. Thread one local `function_indexes_by_callable_id` accumulator.
5. For each added symbol, calculate its final absolute index.
6. Prepend that index to the same-name history in logical insertion order.
7. Update the callable-ID index only for `FuncSymbolKind`.
8. Construct one final `Scope`.
9. Replace the current scope in `Env` once.

Do not repeatedly call `scope_add_symbol` inside the batch. Do not build a list
of intermediate `Scope` or `Env` values.

Measure two implementations before selecting one:

- extend copied indexes through unique local accumulators; and
- rebuild final indexes from `scope.symbols.concat(added_symbols)`.

Use deterministic work and allocation counters to select the crossover. Avoid
an unmeasured size threshold.

## TDD Sequence

Add focused tests to `blorp/test/compiler/stage_05_types/test_env.brp` before changing the
implementation:

1. Empty batch is identity and consumes no IDs.
2. One symbol matches `env_add_symbol` behavior.
3. Mixed variable/function/type/constructor batch preserves insertion order.
4. Repeated names return newest-first complete history.
5. Repeated callable IDs preserve the current exact winner/collision behavior.
6. Callable-ID lookup returns every expected function.
7. Nested scope push/pop restores the previous indexes.
8. Ordinary type shadowing clears accepted containment as before.
9. Accepted type shadowing invalidates only inferred containment.
10. Failed or empty batches do not publish partial state.

Build a test-only oracle by applying the same symbols sequentially through
existing public semantic insertion functions. Compare every public lookup and
history projection; do not expose `Scope` merely for tests.

## Focused Benchmark

Extend `compiler_scope_construction_profile` or add a mixed-symbol mode with:

```text
batch_size: 1, 16, 64, 256, 1024
function_ratio: 0%, 25%, 100%
duplicate_name_ratio: 0%, 25%, 100%
duplicate_callable_id_ratio: 0%, 25%
existing_scope_size: 0, 256, 1024
```

Temporary benchmark-only entrypoints reported semantic checksum, symbol count,
name-history count, callable-index count, elapsed microseconds,
allocations/releases, retained objects, and allocator bytes. Those entrypoints
were removed after selecting an implementation so no public or production
diagnostic surface remains.

Required result:

- no material regression for batch size 1;
- at least 50% fewer scope publications for batch size 16 or greater;
- linear or near-linear allocation growth for fixed existing scope size; and
- no retained-object or allocator-byte regression after the final result is
  released.

## Production Migration In This Issue

Replace `scope_add_type_declaration_symbols` with the mixed implementation and
keep these existing production callers on it:

- ordinary type plus constructor registration; and
- accepted type plus constructor registration.

Do not migrate callable loops in this issue. The mixed-function tests establish
the invariant needed by Issue 17 without coupling this commit to header
conversion and diagnostics.

## Issue 16 Evidence

Raw logs are ignored under `logs/issue16-mixed-scope-batching/`.

### Accumulator vs Final-Index Rebuild

The temporary mixed-symbol matrix ran paired accumulator then rebuild rows for
270 configurations, covering:

- `batch_size`: 1, 16, 64, 256, 1024;
- `function_ratio_percent`: 0, 25, 100;
- `duplicate_name_ratio_percent`: 0, 25, 100;
- `duplicate_callable_id_ratio_percent`: 0, 25; and
- `existing_scope_size`: 0, 256, 1024.

`logs/issue16-mixed-scope-batching/matrix-20260826-234742/` contains raw,
validation, summary, and dimension-analysis files. All 270 pairs had
`workload_valid=True` for both strategies and matching semantic fields and
checksums.

| Strategy | Rows | Total elapsed us | Total allocations | Total releases | Max retained objects | Allocator bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| accumulator | 270 | 15975996 | 57563280 | 57561840 | 20 | 184320 |
| rebuild | 270 | 16574425 | 64479600 | 64473840 | 40 | 737280 |

By dimension, rebuild never won on allocations or allocator bytes. It showed
noisy elapsed-only wins in 14 of 270 paired rows, concentrated in
`existing_scope_size=0` cases where both strategies had equal allocations and
equal allocator bytes for several rows. Those elapsed wins are not enough to
justify rebuilding indexes from scratch because production type publication
frequently extends a non-empty scope, and allocation/release pressure is the
primary target of this issue.

### Legacy Type+Constructor Regression Check

`logs/issue16-mixed-scope-batching/typector-legacy-20260826-235700/` contains a
temporary comparison between the selected accumulator implementation and a
legacy implementation matching the pre-Issue16
`scope_add_type_declaration_symbols` algorithm. It ran paired rows over
`batch_size` 1, 16, 64, 256, 1024; duplicate-name ratios 0, 25, 100; and
existing scope sizes 0, 256, 1024. The run was contended by Spotlight, so
elapsed time is context only. Allocation and work counters are the regression
gate.

All 45 pairs had matching semantic fields and checksums, with
`workload_valid=True` for both strategies.

| Strategy | Rows | Total elapsed us | Total allocations | Total releases | Allocator bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| accumulator | 45 | 2565817 | 8516700 | 8516700 | 0 |
| legacy | 45 | 2571924 | 8516700 | 8516700 | 0 |

The selected accumulator path does not regress the existing type+constructor
consumer on deterministic allocation/release counters in this fixture.

### Generated C

The final generated C inspection used
`logs/issue16-mixed-scope-batching/final-generated-c/compiler_scope_construction_profile.c`.
The selected production helper compiled to one function containing:

- one final symbol-list concatenation;
- one loop over `added_symbols`;
- name-index and callable-ID dictionary accumulator updates; and
- one `Scope_make` in the non-empty path.

There was no generated reference to `scope_add_type_declaration_symbols`. The
temporary rebuild candidate was emitted as a separate function for measurement
only and was removed from final source.

### Limitations And Recommendation

Issue 16 changes only the low-level private scope substrate and the existing
ordinary/accepted type+constructor production consumers. It does not migrate
callable-header publication or declaration phases and should not be described
as a compiler-wide speedup. The mixed callable behavior was exercised only by
temporary measurement code and by preserving existing public callable lookup
tests; Issue 17 remains responsible for a durable production mixed-callable
consumer and its enduring benchmark coverage.

Proceed to Issue 17 with the accumulator strategy as the single private
mixed-symbol scope batch implementation.

## Verification

```bash
./blorp test --timeout 180 blorp/test/compiler/stage_05_types/test_env.brp
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_typecheck_decl.brp
benchmarks/compiler_scope_construction_profile 20 1 1
benchmarks/compiler_scope_construction_profile 20 64 16
benchmarks/compiler_scope_construction_profile 20 256 64
benchmarks/compiler_scope_construction_profile 20 1024 256
scripts/compiler-check --stage types
scripts/compiler-check --stage typecheck
```

Run the relevant leak/sanitizer gate because this changes ownership-sensitive
persistent collection construction.

## Pitfalls

- A local `var` does not prove a collection is uniquely owned. Confirm generated
  C and runtime copy counters.
- Do not infer function symbols from names; match `SymbolKind`.
- Do not silently choose a new duplicate callable-ID policy.
- Do not add the rejected direct latest-name index from Issue 08.
- Do not convert `Scope` to a struct as part of this issue.

## Acceptance Criteria

- One private mixed-symbol batch owns all index maintenance.
- The specialized type batch is removed rather than retained in parallel.
- Existing type/constructor production behavior is unchanged.
- Mixed function/index invariants are covered through public observations.
- Focused allocation and scaling results meet the stated thresholds.
- Generated C shows one final `Scope` construction per batch, not one per
  symbol.

## Merge Point

This is independently mergeable because existing production behavior continues
through the new substrate while callable registration remains unchanged.
