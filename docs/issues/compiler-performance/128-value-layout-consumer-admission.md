# Remove Redundant Value-Layout Consumer Deduplication

**Status:** Proposed; producer-contract proof required

**Current state:** `value_layout_summary_consumers` calls `append_unique_int`
for each dependency even though `value_layout_references` is already unique per
owner and each `owner_index` is processed once. The retained self-compile
observed the graph builder once.
**Next action:** Encode and test the producer uniqueness contract, then append
each owner directly to its dependency's ordered consumer list.
**Read first:**
`blorp/src/compiler/stage_06_typecheck/headers/type_header_graph.brp` and
`blorp/test/compiler/pipeline/test_type_header_graph.brp`.
**Fast loop:** Run the owning graph suite and proposed value-layout fan-in mode.
**Decision:** Reject direct append if duplicate `(dependency, owner)` edges can
legitimately reach this boundary; do not repair them with an undocumented guess.

## Objective

Eliminate redundant growing consumer-list membership scans without changing
value-layout graph order or SCC behavior.

## Proposed Shape And Invariants

After proving `value_layout_references(table, fields)` returns unique dependency
rows per owner:

```blorp
consumers = consumers.set(dependency, existing.append(owner_index))
```

- Preserve dependency order and owner processing order.
- Preserve conservative generic-layout invalidation, cycles, SCC membership,
  worklist behavior, and deterministic diagnostics.
- Cover repeated/nested type paths, generic records, direct/indirect cycles,
  fan-in, and empty fields.
- Keep ordered consumer lists authoritative; do not replace the graph with a
  dictionary or change `value_layout_references` semantics incidentally.

## Feedback Loop

Extend the proposed type-header graph fixture with owners per dependency,
repeated type-path shapes, fields per record, and SCC size. Report producer
duplicates, consumer comparisons/appends, allocations/releases, instructions,
elapsed time, and graph checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/pipeline/test_type_header_graph.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept only when the producer contract is enforced, consumer membership scans
fall to zero, a high-fan-in production graph improves instructions or
allocations by at least 10%, a small graph stays within 3%, and graph/
diagnostic output matches. Reject if duplicates are legal or eliminating them
merely moves equal work upstream.
