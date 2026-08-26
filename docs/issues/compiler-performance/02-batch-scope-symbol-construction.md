# Batch Scope Symbol Construction

**Status:** Narrow type-and-constructor batch complete; generalized batching deferred

## Issue Summary

Reduce persistent collection churn in `scope_add_symbol` by installing groups
of symbols into the current scope in one ownership-friendly operation instead
of rebuilding `Scope`, its symbol list, and two dictionaries for every symbol.

This issue concerns scope construction. Direct lookup acceleration is a
separate issue in `08-direct-scope-lookup-index.md`; do not mix the two changes
unless measurement proves the representations cannot be changed independently.

## Initial Implementation

The first production slice batches one union type symbol with its ordered
constructor symbols in `compiler/src/stage_05_types/env.brp`. It preserves the
existing one-symbol path for declarations without constructors. The batch is
private and intentionally narrow: it cannot contain function symbols, so the
callable-ID index remains unchanged.

The implementation reserves any missing constructor IDs before installing the
group, then builds the final symbol list and same-name index once. Ordinary and
accepted-header batches retain their distinct containment behavior: an ordinary
type shadow clears inferred and accepted facts, while an accepted-header shadow
invalidates only inferred summaries. Scope push/pop continues to restore the
prior containment snapshot.

The focused benchmark reports a 35% allocation reduction for 256- and
1,024-constructor groups, with corresponding elapsed-time reductions in the
same-machine comparison. Separate production `typecheck_graph` comparisons
show a 6.0% median improvement at 256 constructors and 12.9% at 1,024, with
byte-identical typed artifacts. The recorded inputs, outputs, and limitations
are in [`compiler_scope_construction_batch_2026-08-26.md`](../../../benchmarks/results/compiler_scope_construction_batch_2026-08-26.md).

Future slices should migrate only callers that can prove their full declaration
group is atomic; callable-header and ordinary declaration loops remain
sequential until then.

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

## Deferred Generalization

The implemented API is deliberately narrower than the original proposal:

```blorp
private pure func scope_add_type_declaration_symbols(...)
private pure func env_add_type_declaration_symbols(...)
private pure func env_add_accepted_type_declaration_symbols(...)
```

It accepts only a type declaration and constructor symbols, so it does not
need to reconstruct or update the callable-ID index. Do not replace it with a
generic `env_add_symbols` helper until a caller can demonstrate that all of its
symbols are installed atomically and that function-index semantics are covered.

The following broader API remains a future design, not a requirement of the
completed slice:

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

## Completed Sequence

1. Inventory `env_add_symbol` loops; accepted union-header registration was
   selected because its type and constructors are already one atomic plan.
2. Add focused construction coverage for constructor IDs, duplicate names,
   containment, and scope restoration.
3. Implement a private type-and-constructor batch that rebuilds only the symbol
   list and name history index once.
4. Preserve the existing one-symbol path for declarations without constructors.
5. Add focused allocation measurements and a production graph comparison.
6. Defer any generic batch API until a later caller proves atomic installation
   and callable-ID behavior is explicitly modeled and tested.

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

The completed type-and-constructor tests cover:

- one-item and repeated constructor names with exact lookup order;
- reserved and minted constructor IDs;
- accepted and ordinary type-binding shadow invalidation; and
- nested scope push/pop restoration of containment facts and constructors.

Any generalized batch must add separate coverage for mixed functions, variables,
constructors, types, and callable-ID lookup before it can reuse this work.

Run leak checking or the compiler sanitizer gate for any new ownership-sensitive
path.

## Acceptance Criteria

- [x] One production bulk caller uses the batch API.
- [x] Focused fixtures preserve observable type/constructor, ID, containment,
  and scope-restoration behavior.
- [x] The 256- and 1,024-constructor workloads reduce allocations and elapsed
  time; exact values are recorded with the benchmark.
- [x] One-constructor insertion does not materially regress.
- [x] The implementation adds no process-global mutable state or cache.
- [x] A bounded production frontend workload reports paired phase time.
- [x] An explicit `check --capture-typecheck-request PATH` mode produces a
  replayable production request before typechecking.
- [ ] The captured compiler CLI replay is currently about 80 seconds; use its
  phase trace to reduce CTFE dependency checking before treating it as a fast
  inner-loop benchmark.
