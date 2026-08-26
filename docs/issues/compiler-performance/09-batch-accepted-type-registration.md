# Batch Accepted-Type And Constructor Registration

**Status:** Ready after or alongside the shared scope batch primitive

## Issue Summary

Prepare an accepted type and all of its constructor symbols as one ordered
registration plan, assign constructor IDs once, and install the plan into the
environment in one batch. Avoid returning a new `Env` for the type and then for
every variant.

This issue is a high-volume caller of the scope construction work described in
Issue 02. It should reuse that primitive rather than introduce a second
competing batch implementation.

## Profile Evidence

The compiler self-compilation baseline took 180.545 seconds, performed 704.1
million allocations, and reached 2.218 GB peak RSS. External sampling attributed
3,116 samples, 2.073% and about 3.78 seconds, to
`env.env_add_accepted_type_with_containment` and the standard-library/runtime
work directly beneath it.

This cost overlaps with `scope_add_symbol` because the function calls
`env_add_symbol` once per type and once per constructor. Do not add the two
sample percentages as projected savings.

## Current Code

Primary file: `compiler/src/stage_05_types/env.brp`.

`env_add_accepted_type_with_containment` constructs the type symbol and calls
`env_add_accepted_type_symbol`. If constructors are requested, it then loops
over variants. For each variant it:

1. uses a reserved constructor ID or calls `env_mint_def_id`;
2. constructs a `ConstructorSymbol`; and
3. calls `env_add_symbol`, replacing the environment again.

`env_add_accepted_type_with_constructor_ids` then performs another record
update to install accepted containment facts. A closely related
`env_add_type_with_constructor_ids` duplicates much of the same loop.

## Problem Statement

A union with N variants creates N+1 sequential environment insertions plus a
containment update. All symbols and reserved IDs are known before insertion,
so intermediate externally visible environments are unnecessary. The duplicate
accepted/non-accepted loops also increase maintenance risk.

## Goals

1. Assign all constructor IDs deterministically before environment insertion.
2. Build an ordered symbol registration plan for the type and constructors.
3. Install the symbols with one batch scope/environment update.
4. Apply accepted containment metadata once.
5. Share planning logic between accepted and ordinary type registration where
   semantics are truly identical.

## Non-Goals

- Do not change constructor ID ordering or tags.
- Do not merge accepted and unaccepted type APIs when their containment
  contracts differ.
- Do not make constructors visible before the type is valid.
- Do not change union/enum source semantics.
- Do not redesign definition identity allocation.
- Do not duplicate the scope batch API from Issue 02.

## Proposed Design

Create one private plan product. Use the repository's current ID types where
available; this sketch shows shape only:

```blorp
private record TypeRegistrationPlan {
	next_def_id: Int,
	symbols: List[Symbol]
}
```

The plan builder receives the type symbol, variants, `with_ctors`, reserved
constructor IDs, and current allocation frontier. It returns symbols in the
exact order repeated insertion uses: type first, then variants in source order.

Reserved IDs do not advance the frontier under current behavior. Minted IDs do.
Confirm and test this explicitly before coding.

Apply the plan with the batch environment insertion primitive. Then set
`accepted_type_containment[name]` once for accepted types. If adding the type
would invalidate previously inferred containment because of shadowing, the
batch operation must reproduce that invalidation before installing the accepted
fact.

## Mechanical Implementation Sequence

1. Add equivalence tests comparing current registration with an expected list
   of symbols, IDs, lookup results, and containment facts.
2. Add a benchmark with independently controlled variant count and reserved-ID
   ratio.
3. Extract a private constructor-symbol/ID planning function without changing
   insertion yet.
4. Verify the extracted plan reproduces exact ID sequence and tags.
5. Implement or reuse `env_add_symbols` from Issue 02.
6. Replace the accepted-type insertion loop with one plan application.
7. Apply containment facts once after successful symbol insertion.
8. If safe, use the same plan builder in `env_add_type_with_constructor_ids`;
   retain distinct final containment behavior.
9. Remove duplicated loops only after focused tests pass.

## Invariants And Pitfalls

- Type symbol precedes constructor symbols in insertion order.
- Constructor lookup order for duplicate names remains source-order equivalent
  to repeated insertion.
- Reserved constructor IDs are used exactly and do not accidentally advance or
  regress `next_def_id`.
- Minted IDs are contiguous in the same order as before.
- `with_ctors = False` installs no constructors and does not consume IDs.
- Constructor fields, parent type, type parameters, and tags remain exact.
- Resource and function/stream/source containment facts remain exact.
- Shadowing invalidates stale containment, but the newly accepted type's fact
  is present in the final environment.
- A failed/invalid registration must not expose a partially installed plan.

## Fast Feedback Loop

Add a focused benchmark that reports:

```text
iterations
variant count: 0, 4, 16, 64, 256
reserved ID ratio: 0%, 50%, 100%
with_ctors: true/false
final next_def_id
symbol/constructor counts
lookup/ID checksum
elapsed microseconds
allocations/releases
```

Separate plan construction from environment application if possible. Compare
the batch operation with repeated insertion in the same fixture until the new
path is proven equivalent.

## Functional Tests

Run:

```bash
./blorp test --timeout 180 compiler/tests/test_compiler_env.brp
./blorp test --timeout 180 compiler/tests/test_compiler_type_header_graph.brp
./blorp test --timeout 180 compiler/tests/test_compiler_type_header_dependencies.brp
scripts/compiler-check --stage types
scripts/compiler-check --stage typecheck
```

Cover unions, enums, zero variants, many variants, no-constructor mode, reserved
and minted IDs, generic fields, resource-containing types, opaque aliases,
duplicate names, and containment restoration across scopes.

## Acceptance Criteria

- Accepted type registration performs one batch symbol installation rather
  than N+1 environment replacements.
- Constructor IDs, tags, symbol order, lookup behavior, and containment facts
  are identical.
- The 64- and 256-variant workloads materially reduce allocations and elapsed
  time.
- `with_ctors = False` and reserved-ID behavior have explicit regressions.
- Shared planning removes duplicated constructor loops only where contracts are
  identical.
- All types/typecheck focused tests and ownership checks pass.

