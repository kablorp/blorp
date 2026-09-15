# Batch Parser-Finalization Diagnostics

**Status:** Proposed

**Current state:** `finalize_exprs` appends finalized expressions and repeatedly
concatenates each child's diagnostics into a growing list. It ran 156,548 times
in the retained self-compile.
**Next action:** Add a diagnostic-density fixture and replace repeated concat
with one ordered accumulator.
**Read first:** `blorp/src/compiler/stage_03_parse/source_ast_finalize.brp`,
`blorp/test/compiler/stage_03_parse/test_source_ast_finalize.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_03_parse/test_source_ast_finalize.brp`.
Add a diagnostic-density interpolation-finalization fixture before changing
the accumulator.
**Decision:** Preserve diagnostic text and source order byte-for-byte; do not
change parser recovery or AST ownership in this issue.

## Objective

Accumulate parser-finalization diagnostics without repeatedly copying earlier
diagnostics and without changing AST or diagnostic output.

## Why and proposed shape

```blorp
for item in items:
	finalized = finalize_interpolation_expr(module_name, item)
	values = values.append(finalized.value)
	diagnostics = diagnostics.concat(finalized.diagnostics)
```

`List.concat` copies the accumulated prefix. Append each child diagnostic into
one uniquely owned list, or collect child chunks and flatten once. Keep value
construction unchanged so the experiment isolates diagnostics.

Add a focused fixture varying expression count, diagnostics per expression,
empty child diagnostics, nesting depth, and source locations. Report finalized
expressions, diagnostic elements produced, accumulated-prefix elements copied,
allocations/releases, and exact AST/diagnostic checksums. Include the common
zero-diagnostic path so an optimization does not tax successful programs.

## Invariants and tests

- Finalized expression order is unchanged.
- Diagnostics retain exact text, spans, and source order.
- Multiple diagnostics from one expression remain contiguous and ordered.
- Missing/unsupported/interpolation nodes retain current recovery behavior.
- The zero-diagnostic path does not introduce an unnecessary retained builder.

Write a regression with diagnostics from at least two sibling expressions
before implementation and assert their exact ordered messages.

## Acceptance and rejection

Accept if prefix-copy work is eliminated, diagnostic-heavy fixtures improve
retired instructions or allocations by at least 10%, ordinary valid input is
within 2%, and AST/diagnostic checksums match. Run the owning suite,
`scripts/compiler-check --changed`, and `scripts/test compiler-blorp`.

Reject if diagnostics are reordered, if a general parser result redesign is
required, or if the change adds cost to every clean expression without a
measured end-to-end benefit.
