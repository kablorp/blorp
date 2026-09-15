# Step 3 Completion: Publish Complete Body Outcomes Directly

**Status:** Implemented and accepted in the current worktree. This closes
Step 3 of the normalized semantic compilation roadmap.

## Context

Step 3a introduced `BodyOutcomeTable` as the validated, definition-keyed body
row store. Steps 3b through 3d grouped CTFE work once, retained validated
tables across the CTFE handoff, and admitted linked CTFE rows without a
per-module outcome-list copy. Two correctness gaps and two avoidable costs
remained:

- a partial CTFE table and an ordinary complete table had the same type;
- table insertion order could be mistaken for public source order;
- ordinary compilation first built `List[BodyCheckOutcome]`, then copied it
  into a dictionary;
- seed admission tested each row against all planned contexts, while the new
  complete refinement needed to avoid adding a second coverage scan after the
  exhaustive seed-fill loop.

Those gaps made it possible for a future full materializer to consume an
incomplete relation or depend on dictionary order. They also kept transient
collections and quadratic seed-admission work in the production path.

## Product contract

`BodyOutcomeTable` remains the sole partial keyed authority. CTFE may publish
an empty or partial instance because reachability deliberately checks only a
subset of source bodies. Ordinary materialization now requires a distinct
opaque refinement:

```blorp
private record CompleteBodyOutcomeTableRep {
	table: BodyOutcomeTable,
	source_order: List[CallableId],
	main_policy: MainValidationPolicy
}

opaque type CompleteBodyOutcomeTable = CompleteBodyOutcomeTableRep

private union FunctionBodyMaterialization:
	InferStandaloneFunctionBodies
	ReuseSelectedFunctionBodies(BodyOutcomeTable, CallableHeaderGraph)
	ReuseCompleteFunctionBodies(CompleteBodyOutcomeTable, CallableHeaderGraph)
```

The refinement owns no second outcomes collection. It wraps the authoritative
partial table and adds the canonical source-order identity projection. Its
checked public constructor proves exact coverage: every planned context has
one matching outcome, no extra or stale outcome is present, provenance
matches, the `main` outcome was checked under the requested validation policy,
and source order comes from the accepted body plan rather than the checking
schedule. Full materialization derives the policy from this proof-carrying
product rather than accepting a separate value that could disagree.

`ReuseCompleteFunctionBodies` may still infer a parsed declaration whose
accepted header explicitly classifies it as non-source. Native and compiler
probe declarations require that path and are not members of the independent
source-body plan. A missing admitted `SourceCallableBody` remains an internal
error; it never silently falls back to a second body check.

## Implementation strategy

### 1. Publish ordinary rows during body checking

The ordinary producer inserts each result into one local
`Dict[Int, BodyCheckOutcome]` as soon as checking finishes. It does not retain
an outcome list and replay it through `body_outcome_table_for_base`:

```blorp
var rows: Dict[Int, BodyCheckOutcome] = {}

for context in ordered_body_contexts(draft.contexts, order):
	outcome = check_body_context(context)
	id = body_check_outcome_callable_id(outcome)
	rows = rows.set(callable_id_definition_id(id), outcome)
```

The table is wrapped only after the loop. Generated C confirms that `rows` is
the one local writer and no published table retains its dictionary during
insertion, preserving unique COW updates.

### 2. Separate source order from schedule order

Body checks may run in source, reverse, or deterministic shuffled order.
`BodyCheckMetrics.checked_order` records that schedule. The complete product
publishes canonical source order independently. The common source-order path
reuses the already-built scalar-ID list; alternate schedules project the
canonical contexts after checking.

Tests cover top-level functions, explicit and default implementation methods,
rejected bodies, and shuffled schedules. A rejected body is a complete row:
coverage describes whether checking produced an outcome, not whether the
program was accepted.

### 3. Keep CTFE scheduling order out of dictionary iteration

The bridge no longer calls `body_outcome_table_typed_functions`. That helper
projected typed functions by iterating a dictionary and therefore coupled
semantic order to table insertion behavior. CTFE now follows the checked-row
chain in `CtfeCheckedBodyGroups`, validates its module and length, and projects
typed functions in explicit worklist order. The validated `BodyOutcomeTable`
continues to serve keyed lookup and seeded ordinary completion.

### 4. Make seed admission linear

The former `seeded_body_context_*` helpers repeatedly scanned the complete
context list. Admission now builds one `Dict[Int, CallableId]` index and checks
each seed row with an exact identity comparison. This changes the boundary
from `O(planned bodies × seed rows)` to `O(planned bodies + seed rows)`.

After admission, seeded completion visits every canonical context once,
reusing or replacing its exact table row. That loop itself proves the final
table is complete, so it constructs the refinement directly instead of
adding another expected-ID dictionary and scanning the complete table a
second time.

### 5. Preserve valid empty products

A bodyless module has a valid empty partial table and a valid empty complete
refinement. Empty does not mean missing: plan provenance and successful
coverage construction distinguish it from an absent product.

## Fast feedback loop

The edit loop is intentionally short and ordered by diagnostic value:

```bash
bin/blorp format \
  blorp/src/compiler/stage_06_typecheck/decl.brp \
  blorp/src/compiler/stage_06_typecheck/bridge.brp \
  blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
make
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
python3 blorp/test/compiler/stage_06_typecheck/support/test_declaration_boundary.py
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_07_ctfe/test_ctfe_typecheck_profile_benchmark.brp
```

The normal retained resource screen uses one cached-worker pair first; direct
worker execution takes less than a second and avoids repeatedly hashing and
rebuilding the benchmark:

```bash
benchmarks/compiler_ctfe_typecheck_profile 1 24 32 retained selected
```

Use `1 1 1024 retained selected` only as the width guard for seed completion.
More generic pairs are unnecessary unless the first direct pair crosses a
roadmap threshold or changes direction.

## Acceptance criteria

- `BodyOutcomeTable` remains the only outcomes row authority and remains valid
  for partial and empty CTFE products.
- Full ordinary materialization accepts only `CompleteBodyOutcomeTable`.
- Missing, extra, duplicate, stale, foreign, and provenance-mismatched rows
  are rejected before a checked refinement is published.
- A `main` outcome checked under a different validation policy cannot be
  refined or paired with full materialization.
- Accepted and rejected bodies both satisfy coverage.
- Source order is explicit and invariant under body-check scheduling.
- CTFE typed-function projection does not iterate `BodyOutcomeTable`.
- Seed admission is linear, and seeded completion does not add a redundant
  coverage proof.
- Bodyless, recursive, method, default-method, shuffled, and selected CTFE
  fixtures retain their behavior and deterministic counters.
- Generated C has one local dictionary writer without a retained COW alias.
- Allocations, retired instructions, peak memory, RSS, and worker size remain
  below roadmap regression thresholds; accepted output and checksums match.

All criteria are met. The focused suites pass 31 body-order cases, 18 CTFE
cases, and 69 structural boundary checks. The retained measurement and binary
provenance are recorded in the
[Step 3 completion result](../../../benchmarks/results/compiler_step3_body_outcome_completion_2026-09-15.md).

## Result and next boundary

The final exact-source point sample retired 3.25% fewer instructions, but a
three-pair reproducibility audit of the immediately preceding candidate ranged
from -0.129% to +0.090%. The slice is therefore accepted as performance-neutral,
not as a demonstrated instruction or latency win. It adds three managed
allocations out of roughly 257,000 (0.0012%) and 624 bytes to the native worker
(0.0096%). The 1,024-body guard also adds only three allocations, confirming no
managed-allocation growth per body; its instruction, peak, and RSS changes all
remain within the roadmap guards. The architectural gains are direct ordinary
row publication, deletion of the old list replay and dictionary-order
projection, and linear rather than quadratic seed admission.

Step 3 is therefore complete. Subsequent work should consume the proven body
product at the Phase 8/9 and codegen-ready boundaries; it should not add
another body collection or reconstruct source ordering from a keyed table.
