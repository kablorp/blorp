# Linearize Runtime-Declaration Projection

**Status:** Ready for a narrow, measurement-first change

**Owner:** Stage 09 Core/runtime projection

**Target:** `project_runtime_program` in `blorp/src/compiler/stage_09_core/runtime_projection.brp`

## Why

`project_runtime_decl` returns zero, one, or several declarations. Its caller
concatenates each result onto a growing `decls` list. Since current
`List.concat` copies the left prefix, projecting many non-generic functions
can do quadratic copying. Native samples landed in `project_runtime_program`
and the list-concat implementation; the runtime-projection phase grew about
7.7x as the controlled fixture grew 4x. The phase also contains tuple SROA,
so the ratio is evidence to isolate, not a function-level attribution.

## What to inspect and change

- Inspect `project_runtime_decl` variants: generic declarations drop out,
  non-generic declarations usually emit one row, an `ImplDecl` can emit many,
  and a runtime ABI union can return an error.
- Replace repeated whole-prefix concat with a single ordered accumulator;
  append each projected row or use a capacity-aware builder. Verify that the
  accumulator is unique at append time and that geometric growth is used.
- Preserve output order, canonicalization through `canonical_decl`, foreign
  includes, and the first-error/early-break behavior. Do not alter projection
  policy or fuse tuple SROA as part of this issue.
- Do not wait for the broader [COW-capable concat issue](../cow-capable-list-concat.md);
  this caller should not request a full-prefix concat for one-row results.

## Fast feedback loop

Use `blorp/test/compiler/stage_09_core/test_core_runtime_projection.brp` as the
functional loop. Add a small direct benchmark for `project_runtime_program`
that constructs 4,096/8,192/16,384 simple Core declarations without parsing
or typechecking. Include separate mixes of zero-row generic declarations,
one-row functions, and multi-row impls. Prepare the Core input before timing.
Count projected rows, canonicalization calls, list-prefix elements copied,
allocations, and a stable output checksum. A C-emission smoke check without
compiling generated C is:

```bash
bin/blorp compile --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-runtime-projection.c blorp/src/main.brp
```

Compare five warm direct runs first, then the `runtime_projection` row and
whole compiler self-emission with the same build configuration. Treat
the phase row as corroboration, not a clean measurement of this function.

## Acceptance, rejection, and rollback

- A work-counter regression fails before and passes after the change;
  functional tests remain green for zero/one/many output rows, stable order,
  ABI-union errors, first-error behavior, and canonicalization.
- Isolated prefix-copy work is linear in emitted rows, with at most 2.5x work
  on each doubling at the two largest sizes; no per-declaration full-prefix
  copy remains in the direct copy counter.
- Direct median time/instructions improve; self-emission does not show a
  repeatable regression. Focused Core, leak/sanitizer, and compiler gates pass.
- Reject a source rewrite if COW keeps the accumulator shared or an alternate
  helper performs the same copies. Roll back on semantic differences or a
  consistent end-to-end regression after confirming the measurements.

See [the developer guide](../../DEVELOPMENT.md) for build and test commands.
