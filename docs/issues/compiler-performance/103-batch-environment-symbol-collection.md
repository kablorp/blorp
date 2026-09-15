# Batch Environment Symbol Collection

**Status:** Proposed

**Current state:** `env_symbols_named` visits scopes in order and repeatedly
concatenates each scope's matching symbols into a growing result. It ran
224,557 times in the retained self-compile.
**Next action:** Measure matches per scope, then replace prefix-copying concat
with ordered ownership-local accumulation.
**Read first:** `blorp/src/compiler/stage_06_typecheck/type_system/env.brp`,
`blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_env.brp`.
Add a width-controlled `compiler_env_symbols_named_profile` fixture before
changing the implementation.
**Decision:** Preserve scope and overload ordering exactly; this is not an
authorization to change environment lookup or shadowing semantics.

## Objective

Collect matching symbols in linear input/output work while preserving exact
scope and overload order.

## Why and candidate

```blorp
var result: List[Symbol] = []
for scope in env.scopes:
	result = result.concat(scope_symbols_named(scope, name))
```

Because `List.concat` allocates and copies both inputs, symbols accumulated
from earlier scopes can be copied again for every later scope. Append each
scope result into one uniquely owned list, or flatten precomputed chunks once.

The fixture must vary scope count, matches per scope, empty scopes, shadowed
names, and overload count. Record scope visits, matching symbols returned,
prefix elements recopied, allocations/releases, and the exact ordered symbol
identity sequence.

## Invariants and tests

- Scope traversal order is unchanged.
- Symbol order within each scope is unchanged.
- All overloads remain present; this function does not select only the nearest.
- Empty and no-match environments return the same value.
- Equal names from distinct definitions remain distinct entries.
- `env_lookup` and mutation paths are outside scope.

Add explicit multi-scope ordering and duplicate-spelling tests before editing.

## Acceptance and rejection

Accept when prefix-copy work is eliminated, wide-scope allocations or retired
instructions improve by at least 10%, shallow cases stay within 2%, and the
ordered checksum matches. Run the owning environment suite,
`scripts/compiler-check --stage typecheck`, and a compiler self-compile.

Reject if a dictionary replaces the ordered result, if collection changes
shadowing behavior, or if a new general environment representation is required.
