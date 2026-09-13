# Step 3d: Admit Linked CTFE Rows Without Per-Module Outcome Lists

**Status:** Implemented in this worktree; Step 3 remains open.

## Why this cut

Step 3c retained validated `BodyOutcomeTable` values across the CTFE-to-ordinary
handoff, but admission still copied each module's checked outcomes into a
transient list. The worklist already owned one flat checked-row list and a
module-to-row chain, so the extra outcome list carried no new authority.

This cut walks each module's row chain and admits its outcomes into a local
dictionary. Only after the scan completes is the validated table placed in
the graph-scoped module map:

```blorp
outcome_at = pure func(index: Int) -> Option[BodyCheckOutcome]:
	match representation.rows.get(index):
		Some(body):
			if module_ids_equal(body.module_id, registration.module_id):
				Some(body.outcome)
			else:
				None
		None:
			None

match body_check_registry_outcome_table_from_indexed_rows(
	registration.registry,
	first_row_index,
	representation.next_row_index,
	outcome_at,
	expected_count,
):
	BodyOutcomeTableAccepted(table): Some(table)
	BodyOutcomeTableRejected(_): None
```

The indexed admission function checks plan provenance, exact module ownership,
duplicate definition IDs, missing rows, and malformed chain length/cycles. It
keeps the evolving dictionary in one local variable; the public batch builder
and list-facing materializers remain intact. An empty chain produces a valid
empty partial table, so a bodyless dependency stays in selective CTFE mode.
The module chain preserves worklist insertion order for the transient
typed-function projection; ordinary materialization continues to use parsed
declaration order.

## Scaling boundary

A first experiment put each table in the outer module dictionary *during*
worklist traversal and updated it for every accepted body. That retained map
also owned the previous table value. `Dict.set` copies a shared dictionary, so
each update to a wide module could copy its existing rows and become
quadratic. The experiment was dropped before acceptance. This cut keeps the
per-module table local until all its rows are admitted, then retains it once.
The row-index adjacency remains transient; the prepared graph retains only
validated tables.

An intermediate opaque-builder prototype was also rejected. Generated C
retained the builder's dictionary before each insertion, despite the
`builder = admit(builder, row)` call shape. That made prefix copying possible
for a wide module and increased selected-workload allocations by 156 over the
Step 3c worker. The indexed view instead keeps one local dictionary inside the
entire scan. This is not direct publication from the worklist: a future writer
must accept interleaved module rows without introducing a shared nested
dictionary or a second retained outcome authority.

## Fast feedback and acceptance

The focused loop is:

```bash
python3 -m unittest blorp.test.compiler.stage_06_typecheck.support.test_declaration_boundary
bin/blorp test blorp/test/compiler/stage_06_typecheck/test_body_check_order.brp
bin/blorp test blorp/test/compiler/stage_07_ctfe/test_ctfe_typecheck_profile_benchmark.brp
benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained selected
scripts/compiler-check --changed
```

The new indexed-admission test compares a reversed row chain with the batch
builder, and checks zero/partial/full counts, duplicate and cross-plan
rejection, short chains, and cycles. The structural check requires admission
from linked rows without `ctfe_checked_body_groups_outcomes` or an
`outcomes.append` copy. The CTFE suite protects selected reuse, a 16-body
same-module chain, bodyless dependencies, and fallback counters.

Final verification passed: 57 structural checks, 23 body-order cases, 18 CTFE
cases, seven changed-owner suites, and the broad `compiler-blorp` gate
(4,556 / 4,556 tests). Code review found no actionable correctness issue.

Accept this packet only if all focused and changed-owner checks pass, selected
reuse and checksum are unchanged, the wide-chain guard has no scaling failure,
and allocations, retired instructions, peak memory, and code size remain below
the roadmap investigation thresholds. This cut is a data-flow simplification;
it does not by itself meet Step 3's majority-metric acceptance criterion.

## Selected resource screen

The committed Step 3c worker was compared with the final indexed-view
candidate on the retained, selected 3 × 24 × 32 workload. Both yielded
checksum 2,538, 72 dependency body checks, three reused body checks, and
3 / 192 retained objects/bytes. Managed allocation/release calls moved
770,952 / 770,949 → 770,955 / 770,952, or three more allocations (0.0004%).
The worker grew 1,376 bytes, from 6,355,632 to 6,357,008 bytes (0.022%).
Two short direct pairs were near instruction parity:

| Pair | Step 3c instructions | Step 3d instructions | Step 3c peak footprint | Step 3d peak footprint | Step 3c RSS | Step 3d RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1,568,364,435 | 1,568,820,313 | 14,975,288 | 15,024,440 | 20,004,864 | 20,004,864 |
| 2 | 1,568,792,846 | 1,568,499,051 | 14,876,984 | 15,008,056 | 19,906,560 | 19,988,480 |

Peak footprint is 0.3–0.9% higher in these pairs, while RSS is equal or 0.4%
higher. Retired instructions move in both directions within 0.03%; no latency
win is claimed. These samples are a guard screen, not proof that the full
compiler became faster. The generated candidate C has one local `rows`
dictionary and `rows = set(rows, definition_id, outcome)` in the indexed
scanner, without the builder-held dictionary alias seen in the rejected
prototype. That verifies the intended COW ownership mechanism for this cut.

An earlier, superseded local-table prototype was screened with a coarse
5-repeat run of the 18-case CTFE suite on main and the worktree. Both passed
all 90 cases; the prototype's total was 64.76 versus 64.08 seconds and
758.91B versus 758.39B retired instructions. Artifact compilation dominates
that command, so those totals cannot isolate wide-chain runtime cost and are
not evidence for the final indexed-view candidate. A dedicated
width-sensitive worker remains useful before a graph-wide direct writer is
accepted.

## What remains

Step 3 still needs source-order rows and a complete-body coverage contract.
The transient checked-row list and adjacency could later be replaced by a
single graph-scoped row writer, but only after a width-sensitive benchmark
proves that writer avoids shared-inner-table copies. Avoid moving source
strings into later phases merely to provide diagnostics; retain source tables
at the boundary while semantic rows carry IDs and derived values.
