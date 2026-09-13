# Avoid Per-Header Dictionary Copies in Callable-Header Graph Build

**Status:** Investigate ownership, then optimize the proven copy site

**Owner:** Stage 06 typecheck/header graph construction

**Target:** `append_callable_header` in `blorp/src/compiler/stage_06_typecheck/headers/callable_headers.brp`

## Why

For each accepted header, the builder appends to `state.callables` and inserts
`definition_id -> index` into `state.callable_index_by_definition_id` inside
a record update. Native sampling of a many-function fixture landed in
`append_callable_header`, `blorp_dict_cow`, and `blorp_dict_copy`; the typed
frontend grew about 7.1x over a 4x fixture-size increase. Those data implicate
avoidable copying but do not prove whether the record update, a retained old
state, or another caller causes dictionary sharing.

This is distinct from [callable-header registration](05-callable-header-registration.md),
which concerns semantic-type conversion and environment installation *after*
headers are built. Keep their measurements and edits separate.

## What to inspect and change

- Trace ownership of `CallableHeaderBuildState`, its index dictionary, and
  `with_header` through `append_callable_module_range` and the build loop.
  Count dict copies/entries copied per accepted header, and also inspect the
  `callables` list and module-range dictionary.
- If the index is shared due to record-update evaluation, evaluate an owned
  local accumulator or a narrowly scoped batch build of accepted `(id, index)`
  pairs. Install the final index once if that preserves lookup/diagnostic
  timing. Avoid a broad header-graph redesign.
- Preserve exact definition-backed IDs, first/duplicate handling, accepted
  header order, module ranges, errors and their order, and `callable_header_graph_find`
  results. Capacity reservation is useful only after uniqueness is established.

## Fast feedback loop

Use `blorp/test/compiler/stage_06_typecheck/test_callable_headers.brp` for
functional checks. Add a direct header-graph benchmark that constructs the
declaration skeleton/type-header prerequisites outside timing and varies
accepted headers per module (1,024/2,048/4,096), module count (1/8/32), and
zero versus mixed-error inputs. Report accepted/error counts, index checksum,
dictionary copied entries/bytes, list copies, allocations, and elapsed time.
For a production-shaped frontend smoke check that works before the bounded
fixture from the [registry issue](94-avoid-callable-name-registry-copies.md)
exists, use:

```bash
bin/blorp check --no-format blorp/src/main.brp
```

Run five warm samples, record a fresh baseline, and use full C-emission
`typed_frontend` timings only as corroboration because that row covers much
more than header construction.

## Acceptance, rejection, and rollback

- A work-counter regression fails before and passes after the change;
  functional tests remain green for accepted source and foreign headers,
  generics, duplicates/errors, and multiple modules. Verify that
  implementation/default-method skeletons remain excluded at this boundary.
  IDs, index lookups, module ranges, and diagnostic order remain exact.
- Isolated dictionary copied-entry work is amortized linear in accepted
  headers; each doubling at the two largest sizes increases it by at most
  2.5x. Native samples and generated C must be consistent with the measured
  disappearance of repeated full-index copies.
- Direct median time/instructions improve, without a repeatable typed-frontend
  or self-emission regression. Focused typecheck, leak/sanitizer, and compiler
  gates pass.
- Reject a change that shifts quadratic work into pair-list construction or
  delays validation incorrectly. Roll back if header lookup or diagnostics
  change or if memory cost outweighs the measured improvement.

See [the developer guide](../../DEVELOPMENT.md) for build and test commands.
