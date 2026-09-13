# Linearize Nested-Declaration Hoisting

**Status:** Ready for a narrow, measurement-first change

**Owner:** Stage 03 parse/source AST finalization

**Target:** `hoist_nested_decls` in `blorp/src/compiler/stage_03_parse/source_ast_finalize.brp`

## Why

For each ordinary top-level function, `hoist_nested_decls` concatenates the
accumulated declarations with the (usually empty) list of newly hoisted
functions, then appends the function itself. Current `List.concat` copies its
left operand. A native sample of a single-module declaration-scaling fixture
landed in this function and `blorp_list_copy_span_uninit`; parse-only work grew
substantially faster than the number of functions. This is strong evidence of
avoidable repeated prefix copying, not proof that all parse time is here.

## What to inspect and change

- Trace all three concat branches (ordinary, impl, private function) and
  `hoist_nested_function_decls`; preserve the exact order of hoisted children
  before their enclosing declaration, generated IDs, privacy, spans, and
  diagnostic order.
- First test the cheapest hypothesis: skip concat when `result.hoisted` is
  empty. Do not call the conversion helper just to discover an empty result.
- For nonempty results, consider appending each converted declaration to one
  uniquely owned, capacity-aware accumulator. Confirm generated C/ownership
  actually avoids prefix copies; source-level `append` alone is not proof.
- Keep this local to source finalization. The separate
  [COW-capable concat issue](../cow-capable-list-concat.md) may improve the
  general operation later but is not a prerequisite or a substitute for
  avoiding needless concatenations here.

## Fast feedback loop

Use `blorp/test/compiler/stage_03_parse/test_source_ast_finalize.brp` for
ordering/ID regressions. Add a retained generator under `benchmarks/` for
4,096, 8,192, and 16,384 independent functions in one module; keep each body
bounded (for example, at most 64 calls). Include a second variant with nested
functions and impl/private declarations. Generate fixtures in a temporary
directory, outside the measured process. Until that generator lands, use the
compiler itself as a reproducible parse-only smoke check:

```bash
bin/blorp compile --ast --no-format blorp/src/main.brp >/dev/null
```

Time at least five warm runs at each size, but make the decisive measure a
function-local counter or isolated harness reporting left-prefix elements
copied by hoisting, output declaration count, and diagnostic checksum. The
`--time-phases` table begins after source preparation, so it cannot measure
this target. Record a fresh baseline on the same built compiler before edits.

## Acceptance, rejection, and rollback

- A work-counter regression fails before and passes after the change;
  functional tests remain green for empty and nonempty hoists, nested order,
  generated IDs, private/impl behavior, and errors.
- In the no-nested-function fixture, hoisting copies no accumulated prefix;
  in the nested fixture, measured copied elements grow approximately with
  output size (no repeated full-prefix copies). Doubling fixture size must
  increase the isolated work counter by at most 2.5x at the two largest sizes.
- Parse-only median time and retired instructions improve or remain within
  measurement noise; compiler self-compilation and focused parser checks pass.
- Reject a change that merely moves copying to another helper or alters
  ordering/diagnostics. Revert if isolated work improves but real parse-only
  performance consistently regresses; investigate ownership before retrying.

See [the developer guide](../../DEVELOPMENT.md) for build and test commands.
