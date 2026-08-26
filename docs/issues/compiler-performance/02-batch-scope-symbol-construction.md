# Batch Scope Symbol Construction

**Status:** Ready for investigation and implementation

## Issue Summary

Reduce persistent collection churn in `scope_add_symbol` by installing groups
of symbols into the current scope in one ownership-friendly operation instead
of rebuilding `Scope`, its symbol list, and two dictionaries for every symbol.

This issue concerns scope construction. Direct lookup acceleration is a
separate issue in `08-direct-scope-lookup-index.md`; do not mix the two changes
unless measurement proves the representations cannot be changed independently.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling attributed
11,126 samples, 7.401% and roughly 13.48 seconds, to `env.scope_add_symbol` and
the standard-library/runtime work directly below it.

The profile's hottest runtime leaves include dictionary copy at 7.58%, ARC
element release at 9.01%, dictionary destroy at 3.87%, and list copying/memmove
at 6.65% combined. `scope_add_symbol` directly updates a list and two
dictionaries, making it a concrete source of that churn.

This share is an optimization ceiling, not a promised saving. Some work below
`scope_add_symbol` is required to retain indexes.

## Current Representation

Primary file: `compiler/src/stage_05_types/env.brp`.

`Scope` currently stores:

```blorp
private record Scope {
	symbols: List[Symbol],
	symbols_by_name: Dict[String, List[Int]],
	function_indexes_by_callable_id: Dict[Int, Int]
}
```

For each symbol, `scope_add_symbol`:

1. reads the old same-name candidate list;
2. updates the callable-ID dictionary when the symbol is a function;
3. appends the symbol to `symbols`;
4. prepends its index by concatenating `[symbol_index]` with the old list;
5. sets the new name entry; and
6. returns a new `Scope` record.

`env_add_symbol` then replaces the head scope in `Env.scopes`, potentially
invalidates type-containment summaries, and returns another `Env` record.
Header and accepted-type registration call this repeatedly in loops.

## Problem Statement

The API models bulk declaration installation as a sequence of complete
persistent environment replacements. When the caller already owns the evolving
environment uniquely, that creates avoidable intermediate values, dictionary
copies, releases, and short-lived lists.

The first task is to prove which callers need historical scope snapshots. Do
not assume uniqueness merely because a local variable is reassigned: Blorp
value semantics and closure capture can retain an earlier value.

## Goals

1. Add a private batch operation that installs an ordered list of symbols into
   the current scope with substantially fewer collection replacements.
2. Preserve exact lookup, shadowing, overload, callable-ID, containment, and
   definition-order behavior.
3. Migrate the highest-volume declaration/header installation callers first.
4. Demonstrate lower allocation count and time on a focused construction
   harness.

## Non-Goals

- Do not change public language shadowing or overload semantics.
- Do not convert `Scope` from record to struct without ownership measurements.
- Do not introduce shared mutable compiler state.
- Do not alter `Env` scope push/pop ordering.
- Do not add the direct latest-name lookup index from Issue 08 here.
- Do not redesign type-containment analysis.

## Proposed Design

Add a private API with an explicit ordered batch:

```blorp
private pure func scope_add_symbols(
	scope: Scope,
	symbols: List[Symbol],
) -> Scope:
	...

private pure func env_add_symbols(env: Env, symbols: List[Symbol]) -> Env:
	...
```

The implementation should use local collection accumulators and return one
final `Scope`. It must preserve the same logical insertion sequence as repeated
`env_add_symbol` calls. A later symbol with the same name remains first in
lookup order.

Because public persistent collection operations may still copy when aliases
exist, measure both of these strategies before choosing:

1. Build local `symbols`, `symbols_by_name`, and callable-ID dictionaries, then
   construct one final record.
2. Build the complete indexes directly from `scope.symbols.concat(new_symbols)`
   when the batch is large enough that one rebuild is cheaper than N COW sets.

Do not add an imperative mutation escape hatch solely for this issue. If the
standard collection API cannot express uniquely consumed construction, record
that as a separate runtime/library issue with measurements.

## Mechanical Implementation Sequence

1. Inventory `env_add_symbol` loops and group callers by whether they install
   symbols atomically and in a known order.
2. Write a benchmark fixture that starts from an empty environment and installs
   16, 64, 256, and 1,024 symbols with controlled duplicate-name and callable
   distributions.
3. Add assertions for final symbol count, newest-name lookup, complete same-name
   ordering, callable-ID lookup, and containment validity.
4. Implement `scope_add_symbols` by reproducing repeated insertion semantics.
5. Implement `env_add_symbols`, applying type-binding shadow invalidation once
   if any inserted symbol requires it.
6. Migrate one high-volume caller, preferably accepted type/constructor or
   callable-header installation, without changing that caller's other logic.
7. Compare allocations and elapsed time. If the batch implementation does not
   reduce either, stop and inspect COW ownership before migrating more callers.
8. Migrate other mechanically equivalent loops.
9. Keep `env_add_symbol` as the one-item API, preferably delegating to the batch
   operation only if that does not add one-item overhead.

## Required Semantic Invariants

- Inner scopes precede outer scopes.
- Within one scope, the most recently added same-name symbol is returned first.
- `scope_symbols_named` retains newest-to-oldest ordering.
- The symbol list remains in insertion order because other APIs iterate it in
  reverse to obtain lookup order.
- Every function with a callable ID remains addressable by that ID.
- Duplicate callable IDs preserve current overwrite/collision behavior; do not
  invent a new policy in this issue.
- Adding a type binding that shadows an existing binding invalidates accepted
  containment exactly as repeated insertion does.
- Scope push/pop restores containment snapshots unchanged.
- Batch insertion must not expose a partially installed type and constructor
  set to intervening code.

## Fast Feedback Loop

Add a focused benchmark under `compiler/benchmarks/` with a small shell wrapper
under `benchmarks/`, following `compiler_core_flatten_profile`. Report:

- iterations and batch size;
- distinct and duplicate names;
- callable-symbol count;
- final symbol/index counts;
- workload checksum;
- elapsed microseconds; and
- allocation/release counts when the benchmark runner exposes them.

Run the baseline and candidate with the same built compiler:

```bash
benchmarks/compiler_scope_construction_profile 20 16
benchmarks/compiler_scope_construction_profile 20 64
benchmarks/compiler_scope_construction_profile 20 256
benchmarks/compiler_scope_construction_profile 20 1024
```

The exact script name may be adjusted to repository convention, but do not use
whole-compiler wall time as the only feedback loop.

## Functional Tests

Primary focused suite:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_env.brp
scripts/compiler-check --stage types
scripts/compiler-check --stage typecheck
```

Add tests for:

- empty and one-symbol batches;
- unique names;
- repeated same-name symbols and exact lookup order;
- mixed functions, variables, constructors, and types;
- callable-ID lookup;
- type-binding shadow invalidation;
- nested scope push/pop; and
- equality of final observable environment behavior between repeated one-item
  insertion and batch insertion.

Run leak checking or the compiler sanitizer gate for any new ownership-sensitive
path.

## Acceptance Criteria

- At least one production bulk caller uses the batch API.
- Observable environment behavior matches repeated insertion for all focused
  fixtures.
- The 256- and 1,024-symbol workloads materially reduce allocations and elapsed
  time; report exact before/after values.
- One-item insertion does not materially regress.
- No containment, shadowing, overload, or callable-ID test changes semantics.
- The implementation does not add process-global mutable state or an unbounded
  cache.
- Whole-compiler frontend allocations and phase time are reported even if the
  change is smaller than run-to-run noise.

