# Accumulate Borrowed Temporary-Call Bindings Locally

**Status:** Proposed; measurement-gated local Perceus refactor

**Current state:** `prepare_borrowed_owned_temporary_call` concatenates each
prepared argument's binding list into a growing call-local prefix. The retained
self-compile observed 30,656 calls, but call count does not establish copy cost.
**Next action:** Measure exact binding transfers on real production calls, then
replace concat only if it copies materially.
**Read first:** `blorp/src/compiler/stage_09_core/perceus.brp`,
`blorp/test/compiler/stage_09_core/test_core_perceus.brp`, and the accepted
ownership-local accumulation precedent in the Perceus benchmark results.
**Fast loop:** Run the Perceus suite and focused borrowed-call modes of
`benchmarks/compiler_perceus_memory`.
**Decision:** Preserve all binding and argument order. Leave concat unchanged if
its uniquely owned left side is already amortized.

## Objective

Remove demonstrated growing-prefix work at the temporary-call preparation
boundary without changing ownership contracts or post-Perceus Core.

## Candidate And Invariants

```blorp
prepared_arg = prepare_borrowed_argument(...)
for binding in prepared_arg.bindings:
	bindings = bindings.append(binding)
```

Confirm arbitrary child-list cardinality and generated-C ownership; do not
encode an undocumented singleton assumption. Preserve:

- callee binding before argument bindings and arguments left-to-right;
- temporary numbering, borrowed-view names, drops, casts, and owner lifetimes;
- closure, user, builtin, foreign, and unboxed call contracts; and
- materialization and call reconstruction decisions.

Do not change general balancing, cross-stage ownership ABI, or public profiling
state.

## Measurement And Commands

Use `benchmarks/compiler_perceus_memory` at the direct Perceus window with
argument width and child bindings per argument independently controlled. Report
prepared bindings, modeled transfers, allocations/releases, retired
instructions, elapsed time, and exact post-Perceus Core hash.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
python3 -m unittest blorp.test.compiler.benchmark.test_perceus_memory
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

## Acceptance And Rejection

Accept when demonstrated prefix transfers fall by at least 80%, a 32-managed-
argument case improves instructions or allocations by at least 5%, 1/8 argument
and primitive controls stay within 3%, and Core/C plus ARC balance match. Reject
if concat is already amortized, append loops create equivalent COW work, or a
toy helper rather than production Perceus is measured.
