# Bucket Implementation Method Skeletons Once

**Status:** Proposed; invocation-local index with an amortization gate

**Current state:** `implementation_methods` scans every callable skeleton for
each implementation and selects entries with a matching `ImplId`. The retained
self-compile observed 227 invocations.
**Next action:** Add multi-implementation ordering tests and measure
implementations against unrelated callable width before building one bucket map.
**Read first:**
`blorp/src/compiler/stage_06_typecheck/headers/implementation_headers.brp`, the
declaration skeleton owner, and
`blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp`.
**Fast loop:** Run that suite and the proposed implementation-width production
header profile.
**Decision:** Key only by exact `ImplId`/definition identity and keep the index
local to graph construction. Reject it if building the buckets does not repay
the scan on real widths.

## Objective

Replace implementations × all-callables inspection with one catalog pass plus
one ordered bucket traversal per implementation.

## Proposed Shape

In the owning graph-build frame, walk callable skeletons once and append
implementation/default-method skeletons to an `ImplId` bucket in source order.
Then pass only the matching bucket to `implementation_methods`. Mutate one
owning dictionary frame; helper-by-value designs must be rejected if generated
C or clone counters show bucket copying. Do not retain this reverse index in a
public graph when construction-local state is sufficient.

## Invariants And Scope

- Preserve method source order and explicit/default distinction.
- Preserve overload, missing/default method selection, and exact diagnostics.
- Wrong, missing, and duplicate implementation identities fail as today.
- Cover multiple implementations, interleaved ordinary callables, empty/wide
  method sets, defaults, and stable error ordering.
- Do not change trait lookup, signature resolution, or accepted authority.

## Measurement And Commands

Vary implementation count, methods per implementation, unrelated callables,
and defaults independently around production header construction. Report total
skeleton visits, bucket appends/lookups, clones, allocations, instructions,
elapsed time, and ordered header/diagnostic checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when visits approach one catalog pass plus selected bucket entries, a
wide multi-implementation case improves instructions or allocations by at
least 15%, a one-implementation control stays within 3%, no dictionary clone
traffic appears, and output matches. Reject if keyed identity is weakened, the
index escapes construction, or its build cost shifts rather than removes work.
