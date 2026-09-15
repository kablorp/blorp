# Append Cancellation Propagation Work Without Prefix Copies

**Status:** Proposed; easiest measured local refactor, gated by direct worklist evidence

**Current state:** `analyze_function_cancellation` computes a fixed point over
callers with a cursor into `pending`, but expands that queue with
`pending.concat(callers_by_def_id.get_or(...))`. A compiler self-compile at
`f6af78c0` observed the specialized `CancellationCallableFacts` concat 8,857
times with 646.984 ms self time. The enclosing one-shot analysis used 754.247
ms self and 1,798.680 ms inclusive time.
**Next action:** Put the production fixed-point analysis inside a benchmark
window, count enqueued caller entries and modeled prefix copies, then replace
only the queue expansion with ownership-local appends if the copies are real.
**Read first:** `blorp/src/compiler/stage_10_backend/cancellation_plan.brp`,
`blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`, and the
accepted cancellation child-accumulation result under `benchmarks/results/`.
**Fast loop:** Run the cancellation-plan suite and a proposed propagation mode
of `benchmarks/compiler_cancellation_plan_profile` over chain, fan-in, diamond,
and cyclic call graphs.
**Decision:** Preserve the exact fixed point and deterministic reason order.
Reject the refactor if `concat` already consumes its left side without material
copying or if an append loop merely moves the same COW traffic.

## Objective

Make caller propagation proportional to the number of entries actually
enqueued, rather than to the current queue prefix times the number of summary
changes.

The narrow candidate is intentionally unsurprising:

```blorp
for caller in callers_by_def_id.get_or(entry.identity.def_id, []):
	pending = pending.append(caller)
```

Keep `pending`, its cursor, and all updates in one owning function frame. Do not
introduce a general queue abstraction, deduplicate work, or change cancellation
effect semantics in this issue. Deduplication would change processing order and
requires separate proof that it cannot suppress a later summary transition.

## Invariants And Tests

- Preserve the initial source order of `facts`.
- Preserve caller order within every `callers_by_def_id` bucket.
- Preserve repeated enqueues when a summary changes more than once.
- Preserve unknown-call, recursive-call, and transitive-call reasons.
- Preserve exact `DefinitionId` identity; names are not call-graph identity.
- Cover no-edge, linear chain, wide fan-in, diamond, self-cycle, mutual cycle,
  and disconnected-function graphs.
- Require identical ordered function summaries, global summaries, cancellation
  plans, diagnostics, and generated C.

## Measurement

Extend the existing benchmark or add a narrowly named sibling that times the
actual `analyze_program_cancellation` production entry point. Fixture creation
and result verification stay outside the profile window. Report:

- functions and call edges;
- summary transitions, caller-bucket entries, enqueues, and dequeues;
- modeled prefix elements copied by the baseline;
- allocations, releases, retained objects, and allocated bytes;
- retired instructions and elapsed microseconds; and
- ordered function-summary and generated-plan checksums.

Use `--profile-mode exact` narrowly on
`stage_10_backend/cancellation_plan::analyze_function_cancellation` to confirm
that work fell at the intended boundary. Then compare matched binaries with
`benchmarks/compiler_pass_compare`.

```bash
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp
benchmarks/compiler_cancellation_plan_profile 50 512 8
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

The existing profile's timed plan-construction window excludes summary setup;
do not cite it as propagation evidence until the analysis call is inside a
dedicated window.

## Acceptance And Rejection

Accept when modeled prefix copying falls by at least 80%, a wide fan-in or
cyclic workload improves allocations or retired instructions by at least 10%,
small/no-edge controls stay within 3%, all semantic checksums match, and the
compiler-self generated C is byte-identical. Reject if queue storage is already
amortized, ordering changes, memory retention grows with processed prefixes, or
the win exists only in a copied toy algorithm.
