# Batch Nested Record-Update Staging

**Status:** Proposed; ownership-sensitive, measurement-gated refactor

**Current state:** `stage_record_layer` concatenates returned field evaluations
and fields into growing prefixes, and `prepare_nested_record_reuse_value`
concatenates each layer's evaluations again.
**Next action:** Add a multi-layer/multi-field ordering test, instrument the
actual record-update ownership pass, then thread accumulators only if counters
show the current concatenations copy or allocate materially.
**Read first:** `blorp/src/compiler/stage_09_core/record_update.brp`,
`blorp/src/compiler/stage_09_core/pipeline.brp`, and record reuse tests in
`blorp/test/compiler/stage_09_core/test_core_pipeline.brp`.
**Fast loop:** Run that Core pipeline suite and a proposed nested-record staging
profile.
**Decision:** Preserve evaluation and COW field order exactly; this issue does
not authorize changing nested-record allocation layout.

## Objective

Remove prefix copies from record-update preparation while keeping the same
single-evaluation, reuse eligibility, and fallback behavior.

## Proposed Shape

```blorp
match resolve_staged_field(...):
	ReplacementStagedField(value):
		staged = staged_field_with_value(...)
		for evaluation in staged.evaluations:
			evaluations = evaluations.append(evaluation)
		for field in staged.fields:
			staged_fields = staged_fields.append(field)
```

Apply the same ownership-local append form across layers only after confirming
that generated C keeps it uniquely writable. Where a branch produces exactly
one item, append directly rather than construct and concatenate a singleton.
If each staged child is statically zero-or-one item, a more precise private
result variant is allowed only as a bounded, independently validated
preparatory refactor.

## Invariants And Tests

- Replacement expressions evaluate once, in source field/layer order.
- Carried and inherited replacements keep exact field positions.
- Invalid/missing/reordered fields reject reuse as before.
- Target-touch checks and chain source/type checks remain unchanged.
- Empty, one-layer, nested, mixed replacement, constructor/literal-match, and
  fallback cases retain identical Core.
- Inspect generated C to confirm binding and reuse order.

## Feedback Loop

The proposed production-pass fixture should vary layers, fields per layer,
replacement ratio, and invalid layer position. Record staged fields,
evaluations, copied-prefix elements, allocations/releases, retired
instructions, elapsed time, and Core/C hashes.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_pipeline.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

## Acceptance And Rejection

Accept when demonstrated prefix transfers are eliminated, the wide
nested-chain fixture improves retired instructions or allocations by at least
10%, a small valid case and equally sized invalid fallback remain within 3%,
and Core/C plus evaluation-order checks match. Reject if baseline concat is
already aggregate-linear, accumulator ownership still triggers per-layer COW,
invalid chains change behavior, or the work expands into the separate
nested-record folding roadmap.
