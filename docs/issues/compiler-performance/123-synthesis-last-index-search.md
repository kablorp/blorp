# Use The Existing Last-Index String Primitive In Synthesis

**Status:** Proposed; small production cleanup with measurement gate

**Current state:** `synth_name.last_index_of` repeatedly allocates a substring
of the remaining suffix and calls `raw_index_of`. The standard String surface
already exposes `last_index_of`, backed by the compiler's raw last-index
intrinsic.
**Next action:** Add suffix-edge tests, use the existing operation directly in
`strip_mono_suffix`, delete the local helper, and profile synthesis names.
**Read first:** `blorp/src/compiler/stage_09_core/synth_name.brp`,
`standard_library/src/string.brp`,
`blorp/src/compiler/stage_09_core/synth_string.brp`, and synthesis tests.
**Fast loop:** Run the focused synthesis suite and inspect generated Core/C for
`synthesis_source_name` cases.
**Decision:** Reuse the existing semantic operation; do not expose the private
raw intrinsic or add another string-search implementation.

## Objective

Remove successive suffix allocations and repeated forward searches from
compiler-owned name decoding.

## Proposed Shape

```blorp
private pure func strip_mono_suffix(name: String) -> String:
	match name.last_index_of(MONO_NAME_MARKER):
		Some(marker_index): name.substring(0, marker_index)
		None: name
```

`String.last_index_of` returns `Option[Int]`; preserve that `Some`/`None`
conversion directly rather than retaining the private helper's `-1` sentinel.
Confirm the standard String surface is already available at this module (and
add the normal import only if resolution requires it). If resolving the public
operation creates a compiler bootstrap cycle, use the already synthesized
internal operation through the narrowest existing boundary and document why.
Do not copy its algorithm.

## Invariants And Tests

- Preserve the old helper's no-marker branch through `None` and the exact final
  marker byte index through `Some(index)`.
- Test absent, single, repeated, prefix, and terminal `__mono_` markers through
  `synthesis_source_name`, including non-ASCII text before the marker. Empty
  needle behavior is irrelevant because `MONO_NAME_MARKER` is fixed and
  nonempty.
- Preserve `strip_mono_suffix`, pure-suffix removal, module decoding, and exact
  synthesized source names.
- Generated Core must use the intended last-index operation without recursion.

## Feedback Loop

Add a proposed production helper fixture varying name length and marker count.
Record substring allocations, searched bytes, allocations/releases, retired
instructions, elapsed time, and exact integer/decoded-name checksums.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_synth.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_synth_string.brp
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_synth_tensor.brp
scripts/compiler-check --changed
```

## Acceptance And Rejection

Accept when the bespoke helper is deleted, suffix substring allocations fall
to zero, repeated-marker names improve instructions or allocations by at least
20%, ordinary absent/one-marker names remain within 2%, and decoded
names/Core/C match. A semantics-preserving deletion may remain as simplification
when realistic cases are neutral and no metric regresses, but it must not be
reported as a performance win. Reject if resolution creates a bootstrap
recursion, index units differ, or the candidate merely moves the same repeated
search into a new helper.
