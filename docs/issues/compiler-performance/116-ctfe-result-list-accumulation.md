# Measure CTFE Flat-Map Result Accumulation

**Status:** Proposed; strict measurement gate because unique-left concat may
already be amortized

**Current state:** `ctfe_eval_list_flat_map_values` concatenates each
callback-produced list into a call-local result. The complexity screen flags a
growing prefix, but the retained self-compile did not observe this function.
**Next action:** Add fanout/error-order tests and measure the production evaluator
with input width and callback fanout varied independently.
**Read first:** `blorp/src/compiler/stage_07_ctfe/eval.brp` and
`blorp/test/compiler/stage_07_ctfe/test_ctfe_eval.brp`.
**Fast loop:** Run the CTFE evaluator suite and the proposed direct flat-map
profile below.
**Decision:** Change this function only if counters prove accumulated-prefix
work. Leave it unchanged if COW concat is already aggregate-linear.

## Objective

Remove demonstrated prefix copying from compile-time list flat-map without
changing callback evaluation, error propagation, or output order.

## Candidate And Invariants

```blorp
for value in values:
	match ctfe_eval_callback_call(context, env, callback, [value]):
		Ok(list_value):
			match ctfe_eval_expect_list(list_value):
				Ok(items):
					for item in items:
						mapped = mapped.append(item)
				Err(error):
					-- preserve the current first-failure branch
		Err(error):
			-- preserve the current first-failure branch
```

This inner-append form is a candidate, not an assumed improvement. Generated C
and allocation counters must show that it avoids work rather than replacing an
efficient concat with more loops. Preserve these contracts:

- invoke the callback exactly once per input, left-to-right;
- stop at the same first callback or expected-list error and retain its span;
- preserve empty, singleton, and multi-item callback results in order; and
- keep allocations/releases balanced.

Do not reevaluate callbacks to precompute capacity, change CTFE list
representation, or add a general builder/public profiling API.

## Fast Feedback And Measurement

Add a proposed `compiler_ctfe_flat_map_accumulation_profile` around
`ctfe_eval_typed_expr`. Vary input width, callback result width, empty-result
ratio, and error position. Keep fixture construction outside the window and
report callbacks, output items, modeled prefix transfers, allocations/releases,
retired instructions, elapsed time, output checksum, and failure position.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_07_ctfe/test_ctfe_eval.brp
bin/blorp run blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/compile_time_list_callbacks.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept only if demonstrated prefix transfers fall by at least 80%, a wide
fanout case improves instructions or allocations by at least 10%, empty and
singleton controls stay within 3%, and output, callback count, error, and
failure position match. Reject if baseline concat is already amortized, the
candidate shifts equivalent work into inner loops, or only copied toy logic is
faster.
