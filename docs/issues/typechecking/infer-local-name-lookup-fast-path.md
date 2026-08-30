# Fast-Path Lexical Name Lookup In Inference

**Status:** Implemented and measured on 2026-08-25. The implementation landed in
commit `0149816b`; the measured baseline is its parent, `8b3381a5`. The detailed
implementation instructions below are retained as the design and verification
record for the completed change.

## Measured Result

Three alternating baseline/candidate runs used the fixed workload:

```bash
benchmarks/compiler_typecheck_profile 5 1 16 256 fallback
```

Every run reported 273 source declarations, 273 typed declarations, zero
errors, and checksum 2740. Median results were:

| Measurement | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Workload elapsed time | 1,897,443 us | 1,767,877 us | -6.8% |
| `lookup_bare_symbol` self time | 62.963 ms | 7.931 ms | -87.4% |
| `env_symbols_named` calls | 2,560 | 0 | -2,560 |
| imported-name lookup calls | 6,495 | 3,935 | -2,560 |
| `env_lookup` calls | 17,885 | 20,445 | +2,560 |

The wall-clock result is specific to this local-heavy fixture. The durable
result is structural: every lexical probe replaces one complete same-name
symbol-list construction and one premature imported-name lookup with one
innermost-scope lookup.

Known residual cost: a lookup that misses the lexical/current-module fast path
performs the added `env_lookup` before entering the original aggregate scan.
The measured common path more than offsets that cost for this fixture, but a
future environment-index change should remove the fallback double traversal
rather than layering another cache onto inference.

## Issue Summary

Avoid constructing the complete same-named symbol list and querying imported
bindings when expression inference can prove immediately that the innermost
environment symbol is a lexical or current-module value.

The change belongs in `lookup_bare_symbol` in
`blorp/src/compiler/stage_06_typecheck/infer.brp`. It is a behavior-preserving
performance optimization. It must retain the current precedence among lexical
symbols, current-module declarations, selective imports, visible module
declarations, constructors, and builtins.

This issue is intentionally narrow. Do not redesign `Env`, module imports,
overload resolution, or symbol visibility while implementing it.

## Context

Every `ParsedNameExpr` reaches `infer_name_expr`, which calls
`lookup_bare_symbol`. The lookup must handle several namespaces and precedence
rules:

1. lexical and current-module symbols;
2. explicit imported-name bindings;
3. otherwise visible module symbols;
4. builtin fallback symbols; and
5. trait-method and constructor fallback handled after `lookup_bare_symbol`.

The current implementation preserves those rules, but it performs expensive
fallback preparation before checking the common case. In simplified form it
does this:

```blorp
private pure func lookup_bare_symbol(
	context: InferContext,
	name: ParsedIdentifier,
) -> Option[Symbol]:
	var local_or_current: Option[Symbol] = None
	var visible_fallback: Option[Symbol] = None
	var builtin_fallback: Option[Symbol] = None
	imported_binding = typecheck_state_find_imported_name(context.state, name.text)

	for symbol in env_symbols_named(context.state.env, name.text):
		-- Classify every same-named symbol until a local/current symbol wins.
		...

	match local_or_current:
		Some(symbol):
			Some(symbol)
		None:
			-- Consult imported_binding and the fallbacks.
			...
```

`env_symbols_named` walks every environment scope and concatenates the matching
symbols from each scope into a new list. For a parameter or local variable, the
first environment symbol already wins. Building the aggregate list and looking
up an import are therefore unnecessary.

## Why This Work Is Worth Doing

A recorded function profile used:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback
```

The local-heavy fixture produced the following relevant measurements:

| Function | Calls | Cumulative time |
| --- | ---: | ---: |
| `infer_name_expr` | 2,560 | 216.348 ms |
| `lookup_bare_symbol` | 2,560 | 55.095 ms |
| `env_symbols_named` | 2,560 | 16.541 ms |
| `typecheck_state_find_imported_name` | 6,495 | 11.789 ms |
| `env_lookup` | 20,450 | 14.278 ms |

The profiler is instrumented and cumulative times overlap. These values are
attribution evidence, not an end-to-end speed claim. The structural evidence is
stronger:

- all 2,560 fixture name lookups are ordinary lexical references;
- all 2,560 calls currently construct the cross-scope result of
  `env_symbols_named`;
- all 2,560 calls currently query imported-name metadata before discovering
  the lexical winner; and
- `env_symbols_named` builds its result with repeated list concatenation.

The proposed fast path should eliminate those two operations for all 2,560
fixture lookups. It replaces them with `env_lookup`, which returns the
innermost symbol directly.

## Relationship To Other Work

This issue is independent of
[Propagate Canonical Expected Types Through Inference](infer-canonical-expectation-propagation.md).
That issue changes expectation construction near the beginning of `infer.brp`;
this issue changes bare-name lookup around `lookup_bare_symbol`. They can be
implemented independently, although an agent must re-read the current file
before editing because both touch `infer.brp`.

This issue does not replace later work to improve environment representation or
make module/name identities less stringly typed. It simply avoids invoking the
existing complete lookup machinery when its answer is already known.

## Problem Statement

`lookup_bare_symbol` currently conflates two paths:

1. the common path where the first environment symbol is lexical or belongs to
   the current module; and
2. the fallback path where imported-name precedence, module visibility,
   constructors, and builtins must be considered.

The common path unnecessarily pays the fallback path's list construction and
import lookup costs.

## Existing Ordering Contract

The fast path is valid because the current `Env` APIs use the same lookup
ordering:

- `env_lookup` iterates `env.scopes` from first to last and returns the first
  `scope_lookup` result.
- `env_symbols_named` iterates `env.scopes` in that same order and concatenates
  each scope's `scope_symbols_named` result.
- `scope_lookup` returns the first index in `symbols_by_name`.
- `scope_symbols_named` iterates that same index list from first to last.

Therefore, when `env_lookup` returns a symbol for which
`symbol_is_lexical_or_current_module` is true, the existing complete scan sees
that same symbol first, stores it in `local_or_current`, and breaks. Returning
it immediately is equivalent to the current algorithm.

Do not generalize this proof. An arbitrary first symbol is not always the final
answer. Builtins, imported module symbols, hidden module symbols, type symbols,
and other fallback candidates must continue through the complete scan.

## Goals

1. Return lexical and current-module symbols without calling
   `env_symbols_named`.
2. Do not call `typecheck_state_find_imported_name` when a lexical or
   current-module symbol wins.
3. Preserve every existing name-resolution and diagnostic behavior.
4. Keep the change local to `lookup_bare_symbol` and its focused tests.
5. Demonstrate reduced work with the existing typecheck profiler.

## Non-Goals

- Do not change `Env`, `Scope`, `Symbol`, or `ModuleView` representation.
- Do not add a symbol cache.
- Do not add a second symbol index.
- Do not replace complete fallback resolution with `env_lookup`.
- Do not change overload or UFCS selection.
- Do not change trait-method lookup.
- Do not change constructor visibility.
- Do not change builtin precedence.
- Do not move name resolution to another compiler phase.
- Do not modify expected-type canonicalization as part of this issue.
- Do not add a public API merely to expose profiler counters.

## Required Implementation

### Step 1: Establish The Baseline

Before editing production code, run the focused inference suite:

```bash
./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

Then capture a profile outside the repository:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback \
  >/tmp/infer-local-lookup-baseline.out \
  2>/tmp/infer-local-lookup-baseline.profile

rg 'infer__lookup_bare_symbol|env__env_symbols_named|state__typecheck_state_find_imported_name|env__env_lookup' \
  /tmp/infer-local-lookup-baseline.profile
```

Record:

- artifact, source declaration, and typed declaration counts;
- error count;
- workload validity;
- checksum;
- calls to the four functions above; and
- elapsed time, while treating timing as noisy supporting evidence.

The historical workload result was:

```text
artifacts=2
source_declarations=273
typed_declarations=273
errors=0
workload_valid=True
checksum=2740
```

If current unrelated work changes those values, explain the new valid baseline
before implementing this issue. Do not force historical counts into tests.

### Step 2: Verify Existing Behavioral Coverage

Read the existing lookup and shadowing tests in
`blorp/test/compiler/stage_06_typecheck/test_infer.brp`. At minimum, retain coverage for:

- a local variable or parameter lookup;
- lexical shadowing of an outer symbol;
- a user function shadowing a builtin;
- a hidden module function not shadowing a builtin;
- a current-module constructor;
- a selectively imported value or function;
- a visible module fallback;
- a builtin fallback; and
- an unbound name preserving the exact existing diagnostic.

Relevant existing tests include:

- `test_hidden_module_function_does_not_shadow_builtin`;
- `test_user_function_shadows_assert_shape_builtin`;
- `test_lambda_allows_parameter_shadowing_mutable_outer`;
- `test_lambda_allows_local_shadowing_mutable_outer`; and
- the existing missing-name tests that assert `Unbound value` diagnostics.

Search the suite for imported-value, imported-function, and constructor tests
rather than adding duplicates. Add only a missing precedence regression. Any
new test must call `infer_expr`; do not make `lookup_bare_symbol` public for
testing.

Performance is the reason for the implementation, while the public behavior is
intentionally unchanged. The profile is the failing performance observation;
the focused tests protect semantic equivalence.

### Step 3: Add The Exact Fast Path

Change only `lookup_bare_symbol` in
`blorp/src/compiler/stage_06_typecheck/infer.brp`.

Initialize `local_or_current` from a direct `env_lookup`:

```blorp
var local_or_current: Option[Symbol] = match env_lookup(
	context.state.env,
	name.text,
):
	Some(symbol):
		if symbol_is_lexical_or_current_module(context.state, name.span, symbol):
			Some(symbol)
		else:
			None
	None:
		None
```

Keep `visible_fallback` and `builtin_fallback` initialized exactly as they are
today.

Run the existing complete scan only after a fast-path miss:

```blorp
if local_or_current.is_none():
	for symbol in env_symbols_named(context.state.env, name.text):
		-- Keep the current loop body unchanged.
		...
```

Do not alter the classification logic inside the loop. In particular, retain:

- builtin functions as `builtin_fallback` rather than immediate winners;
- `symbol_is_lexical_or_current_module` as the only fast winner predicate;
- `symbol_visible_as_bare` for module-visible fallback selection;
- first visible fallback behavior; and
- the loop's early `break` for a lexical/current winner found during fallback.

Do not introduce a new helper function for this small control-flow change.

### Step 4: Defer Imported-Name Lookup

Delete the eager declaration:

```blorp
imported_binding = typecheck_state_find_imported_name(context.state, name.text)
```

Call `typecheck_state_find_imported_name` only in the `None` branch after
`local_or_current` has failed:

```blorp
match local_or_current:
	Some(symbol):
		Some(symbol)
	None:
		match typecheck_state_find_imported_name(context.state, name.text):
			Some(binding):
				-- Preserve the existing imported-symbol/fallback logic exactly.
				...
			None:
				-- Preserve the existing visible/builtin fallback logic exactly.
				...
```

Move the existing branches without rewriting their conditions. The intended
change is evaluation order, not precedence.

### Step 5: Keep The Diff Narrow

The production diff should normally contain:

1. initialization of `local_or_current` through `env_lookup`;
2. an `if local_or_current.is_none()` guard around the existing complete scan;
3. movement of `typecheck_state_find_imported_name` into the final `None`
   branch; and
4. focused tests only if the coverage audit found a real gap.

Do not edit `env.brp`, `state.brp`, or module binding code unless the equivalence
assumption above is no longer true in the current source. If it is no longer
true, stop and request review.

## Expected Final Shape

The resulting function should follow this control flow:

```text
env_lookup(name)
  |
  +-- first symbol is lexical/current ------------------> return it
  |
  +-- absent or not lexical/current
        |
        +-- run existing complete same-name scan
              |
              +-- lexical/current found ---------------> return it
              |
              +-- no lexical/current
                    |
                    +-- query explicit imported binding
                    |     |
                    |     +-- mapped symbol ------------> return it
                    |     +-- missing target -----------> visible/builtin fallback
                    |
                    +-- no imported binding ------------> visible/builtin fallback
```

## Correctness Risks

### Returning Every `env_lookup` Result Immediately

This is incorrect. The first symbol may be a builtin or a module declaration
that loses to an explicit import or another visibility rule. Return early only
when `symbol_is_lexical_or_current_module` is true.

### Changing Fallback Precedence

Imported bindings currently precede `visible_fallback`, which precedes
`builtin_fallback`, except that a missing imported target falls through. Keep
that exact behavior.

### Treating A Type Symbol As A Value Winner

`symbol_is_lexical_or_current_module` intentionally returns false for symbol
kinds that are not lexical/current values. Do not replace it with a module-path
string check or a new name-based heuristic.

### Breaking Constructor Visibility

Current-module constructors use type-home metadata to establish their module.
Do not special-case constructor spelling or infer ownership from names.

### Adding A New Aggregate Allocation

Do not replace `env_symbols_named` with another `filter`, `flat_map`, or list
builder on the fast path. The purpose is to avoid aggregate construction.

### Overfitting To The Benchmark Fixture

The fixture is intentionally local-heavy, but fallback behavior remains
production behavior. Keep and run imported/module/builtin regressions even
though they do not improve the benchmark count.

## Fast Feedback Loop

After the production edit:

```bash
./blorp format --check \
  blorp/src/compiler/stage_06_typecheck/infer.brp \
  blorp/test/compiler/stage_06_typecheck/test_infer.brp

./blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp
```

If a new focused test file is added, register it in
`blorp/test/compiler/compiler_test_ownership.json` and run it separately. Prefer
using the existing inference suite because the change is one private function
and that suite already owns `infer.brp`.

Then rebuild and run the stage-owned tests:

```bash
make
scripts/compiler-check --stage typecheck
```

## Performance Verification

Run the same profile command after rebuilding:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_typecheck_profile 5 1 16 256 fallback \
  >/tmp/infer-local-lookup-candidate.out \
  2>/tmp/infer-local-lookup-candidate.profile

rg 'infer__lookup_bare_symbol|env__env_symbols_named|state__typecheck_state_find_imported_name|env__env_lookup' \
  /tmp/infer-local-lookup-candidate.profile
```

Expected structural results for the recorded local-heavy workload:

- `lookup_bare_symbol` remains at approximately 2,560 calls;
- `env_symbols_named` falls from approximately 2,560 calls to zero;
- `typecheck_state_find_imported_name` falls by approximately 2,560 calls;
- `env_lookup` increases by approximately 2,560 calls;
- artifact/declaration/error/workload/checksum output is unchanged; and
- no replacement list-building function appears on the fast path.

Exact totals may change because of unrelated compiler work. The required proof
is that lexical hits no longer reach `env_symbols_named` or imported-name
lookup, not that historical totals match exactly.

Do not claim an end-to-end percentage from one run. If describing the change as
a measured speedup, collect alternating baseline and candidate samples on the
same machine and report medians. The primary acceptance criterion is eliminated
work and allocation, not noisy wall-clock movement.

## Final Validation

After the focused checks and profile agree, run:

```bash
scripts/compiler-check --changed
scripts/test compiler-blorp
make quality
```

If concurrent work changed `infer.brp`, rebase or reapply only the bounded
`lookup_bare_symbol` edit. Do not overwrite expectation-constructor or other
unrelated inference changes.

## Acceptance Criteria

- [x] A lexical/current-module first symbol returns through `env_lookup`.
- [x] Lexical/current fast hits do not call `env_symbols_named`.
- [x] Lexical/current fast hits do not call
      `typecheck_state_find_imported_name`.
- [x] Fast-path eligibility uses `symbol_is_lexical_or_current_module`.
- [x] The complete existing scan still runs after a fast-path miss.
- [x] Imported, visible-module, constructor, builtin, and unbound-name behavior
      remains unchanged.
- [x] Existing exact diagnostics remain unchanged.
- [x] No cache, new index, new wrapper helper, or `Env` redesign is introduced.
- [x] The benchmark checksum and workload counts remain valid.
- [x] The profile demonstrates elimination of the redundant aggregate lookup
      on the local-heavy fixture.
- [x] Focused inference tests, stage typecheck checks, compiler tests, and
      quality gates pass.

## Stop Conditions

Stop and request review instead of expanding the issue if implementation seems
to require any of the following:

- changing environment or module-view representation;
- changing symbol insertion or shadowing order;
- making `Scope` public;
- adding a new symbol cache or index;
- changing import conflict rules;
- changing builtin, constructor, trait, overload, or UFCS precedence;
- exposing `lookup_bare_symbol` publicly;
- changing diagnostics or typed AST output; or
- modifying expectation canonicalization or solver behavior.

Those may be useful separate projects, but none is required for this fast path.
