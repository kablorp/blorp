# Compute Perceus Ownership-Use Summaries Once Per Subtree

**Status:** Ready. Coordinator-owned acceptance; measurement-first.

**Current state:** `blorp/src/compiler/stage_09_core/perceus.brp` decides
dups and drops from `OwnershipUseSummary` values that it recomputes on demand.
`summarize_linear_ownership_uses(env, name, expr)` walks `expr` from scratch
for one name; it has 135 call sites and ran 4.57M times on the 2026-09-16
self-compile (5.9M calls to its `_non_binding` visitor, 5.3M to
`summarize_call_args`). `protect_repeated_consumes` ran 2.49M times and calls
`summarize_linear_call` at every call node in a repeated context, so nested
calls are re-summarized once per enclosing level. `summarize_repeated_body_uses`
summarizes a body and then walks it again with `count_uses` when a consume was
found. Perceus is 18% of the compiler's self time and about 4 seconds of a
23 second self-compile; the summarization family is roughly 45% of Perceus.

**Next action:** Attribute the summary requests to their root call sites on
the self-compile, then remove the dominant repeated walk by computing that
summary once bottom-up and threading it to the consumer. One root site per
slice; measure after each.

**Read first:** `perceus.brp` functions `summarize_linear_ownership_uses`,
`summarize_linear_ownership_uses_non_binding`, `summarize_call_args`,
`summarize_linear_call`, `summarize_repeated_body_uses`, `count_uses`,
`protect_repeated_consumes`, `plan_managed_let`, `insert_drops_expr_inner_result`;
`blorp/test/compiler/stage_09_core/test_core_perceus.brp` and the other
`test_core_perceus_*.brp` suites; [Ownership Model](../../OWNERSHIP_MODEL.md);
[issue 135](135-core-traversal-perceus-reuse.md) for the earlier profile;
the [measurement protocol](../../../benchmarks/README.md#self-compile-measurement-protocol).

**Fast loop:**

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
make && scripts/compiler-build-status
benchmarks/self_compile_measure --label issue-148-<slice> --input-rev <baseline input_rev> \
  --baseline benchmarks/results/self_compile_baseline_O0_2026-09-16.json \
  --output /tmp/issue-148-<slice>.json --require-identical
```

**Decision:** Accept when generated C is IDENTICAL, Perceus summary node
visits fall by at least 40% on the self-compile, late_core allocations and
total retired instructions fall, and the Perceus, ownership-event, leak, and
sanitizer suites pass. Consult the coordinator before changing the order of
`DupExpr`/`DropExpr` insertion, any ownership contract, or the meaning of an
`OwnershipUseSummary` field.

## Objective

Remove Perceus's repeated per-binding and per-call subtree re-summarization by computing each ownership-use summary once bottom-up and threading it to its consumer, with byte-identical generated C.

## Step 0: Attribute

Build a call-count profile of the compiler compiling the frozen input, limited
to the Perceus module, and record the counts of every `summarize_*`,
`count_uses`, `protect_repeated_*`, and `plan_managed_let` function:

```bash
boot=$(scripts/blorp-compiler-bootstrap --print-path)
input=$(benchmarks/self_compile_measure freeze --rev <baseline input_rev>)
$boot compile --profile-mode calls --profile-module blorp/src/compiler/stage_09_core/perceus \
  --std-dir standard_library/src --no-format -o /tmp/blorp-perceus-calls.c blorp/src/main.brp
cc -O0 -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
  -Iblorp/src/compiler/stage_01_generated_inputs -Iblorp/src/compiler/stage_04_modules \
  -Iblorp/src/compiler/stage_06_typecheck/graph -Iblorp/src/compiler/stage_06_typecheck/type_system \
  -Iblorp/src -Iblorp/src/lib -Iblorp/src/lsp/server -Iblorp/src/test \
  /tmp/blorp-perceus-calls.c blorp/build/_build/blorp-cli/runtime_sources.c \
  blorp/src/lsp/server/native_runtime.c -lm -lpthread -o /tmp/blorp-perceus-calls
/tmp/blorp-perceus-calls compile --no-format --no-embed-runtime \
  --std-dir $input/standard_library/src -o /tmp/x.c $input/blorp/src/main.brp \
  2> /tmp/perceus-calls.txt
```

The `=== Function Calls ===` section lists per-function counts. Use
`--profile-mode exact` for self time when you need it. Keep this profile in
your handoff as the "before" row; rebuild it after each slice.

## Candidate Slices

Pick the slice whose root site dominates the attribution. Each slice keeps
the single-name summarizer as the reference implementation until the slice
is proven.

1. **Nested-call re-summarization in `protect_repeated_consumes`.** Return the
   `OwnershipUseSummary` of the protected subtree alongside the protected
   expression so the parent call's `summarize_linear_call` combines child
   summaries instead of re-walking `protected_args`.
2. **Per-target walks over repeated bodies.** If `protect_repeated_consumes`
   is invoked once per managed variable over the same loop body, walk the
   body once for all targets and produce one summary per target.
3. **Double walk in `summarize_repeated_body_uses`.** Fold the information
   `count_uses(name, whole_expr)` needs into the first summary so the second
   walk disappears.
4. **Let-chain suffix summaries.** For a block spine of `LetExpr`/`BorrowLetExpr`/
   `SeqExpr`, `plan_managed_let` needs the summary of each suffix for its own
   variable. Compute suffix summaries bottom-up once per spine, then look them
   up while inserting drops, instead of walking each suffix from its let.

Prefer the slice with the largest measured share. Stop after the first slice
that meets acceptance and report; a second slice is a separate decision.

## Correctness Oracle

Generated C is the oracle: any change to which dups/drops are inserted, or
where, changes the C. In addition, while a slice is under development, keep a
debug-only comparison that computes the old single-name summary and the new
value at the consumer and reports the first mismatch with its function name
and source location; remove it before handoff. Run:

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
bin/blorp test --leak-check --timeout 180 blorp/test/compiler/stage_09_core/test_core_perceus.brp
benchmarks/self_compile_measure lock -- scripts/compiler-check --changed
benchmarks/self_compile_measure lock -- scripts/test compiler-core-sanitize leak
```

## Invariants

- Exact Core expression variants, types, source locations, variable identity,
  evaluation order, and child order are preserved.
- Every ownership contract, `DupExpr`, `DropExpr`, borrow boundary, reuse
  witness, and cancellation owner lifetime is preserved; generated C is
  byte-identical on the self-compile and the small program.
- Stack depth does not regress: the summarizer is iterative for a reason; a
  new bottom-up computation must be frame-safe on long block spines.
- No new persistent cache with an undefined lifetime. A summary computed for
  a subtree lives only for the enclosing rewrite of that subtree.
- Do not edit `constructor_contract_by_return_type` or `build_env`; issue 149
  owns those lines in this file.

## Measurement

Report the before/after Perceus call-count rows for the root sites, the
harness comparison tables for the self and small programs (IDENTICAL line
included), and the leak/sanitizer results. Primary metrics: Perceus summary
node visits (call counts) and late_core allocations; retired instructions
for the whole compile is the acceptance number.

## Acceptance And Rejection

Accept: IDENTICAL C on both programs; summary visits down at least 40%;
late_core allocations down; total retired instructions down at least 3%;
small program not up more than 1%; all listed suites green. Reject a slice
that changes ownership events, displaces walks into a cache without a
lifetime, or wins only on the synthetic Perceus benchmark.
