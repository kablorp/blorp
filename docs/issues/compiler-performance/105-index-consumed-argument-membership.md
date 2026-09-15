# Index Consumed-Argument Membership

**Status:** Proposed subproblem of Issue 53

**Current state:** Three hot loops scan `List[Int]` consumed-argument indices:
`call_args_transfer_cleanup_pop_statements` ran 160,378 times, while
`direct_consumed_call_vars` and `consumed_call_vars_before_suspension` each ran
87,020 times in the retained self-compile.
**Next action:** Characterize argument and consumed-index widths, then test one
explicit membership representation shared by planning and emission.
**Read first:** `blorp/src/compiler/stage_10_backend/emit.brp`,
`blorp/src/compiler/stage_10_backend/cancellation_plan.brp`, their owning
tests, [Issue 53](53-minimize-and-compact-cancellation-cleanup.md), and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp && bin/blorp test blorp/test/compiler/stage_10_backend/test_core_emit.brp`.
Add a generated-C fixture with mixed consumed and borrowed arguments before
changing the representation.
**Decision:** Preserve exact call ABI and argument order. Ask for guidance
before changing `CoreCallKind` or the cancellation plan's typed contracts.

## Objective

Share one explicit consumed-argument membership representation across the
three scans without changing ownership or cleanup decisions.

## Why

All three loops repeat this pattern:

```blorp
indices = cancellation_call_consumed_arg_indices(kind, args.length())
var index: Int = 0
for arg in args:
	if indices.contains(index):
		-- emit cleanup or record a consumed variable
	index += 1
```

This is `O(args * consumed_args)`. Lists are usually short, so the issue is
admitted by work counters rather than the invocation count alone.

## Candidate representations

Prefer the narrowest explicit representation:

1. a validated boolean mask aligned with argument positions;
2. a private `ConsumedArgumentMembership` that stores an ordered list plus a
   keyed membership companion; or
3. a synchronized two-pointer walk only if ordering is guaranteed by the
   constructor and represented as an invariant, not guessed by callers.

Build the representation once per call analysis and reuse it for the related
queries. Do not maintain independent consumed-argument authorities.

The focused fixture should vary total arguments, consumed density, sparse and
dense positions, call kind, suspension position, and repeated Core variables.
Record list comparisons, membership queries, representation allocations,
cleanup pop lines, consumed variables, and exact plan/C checksums.

## Invariants

- Left-to-right evaluation and cleanup-pop order are unchanged.
- A consumed index outside the argument list remains handled as today.
- Duplicate indices do not duplicate cleanup or ownership units.
- Region-sensitive handoff and non-suspending-prefix decisions are unchanged.
- Constructor, runtime, user, closure, and intrinsic call kinds retain their
  current ownership contracts.
- Representative generated C should be byte-identical.

## Acceptance and rejection

Accept if realistic widths show material comparison work and the candidate
reduces focused retired instructions or allocations by at least 10%, with
byte-identical C and no narrow-call regression above 2%. Run both owning
suites, codegen audit, `scripts/compiler-check --changed`, and cancellation
sanitizer/leak gates.

Reject if index construction exceeds saved scans, if the representation leaks
into unrelated Core phases, or if it relies on undocumented sorted input.
