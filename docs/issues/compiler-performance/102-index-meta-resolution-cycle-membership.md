# Index Meta-Resolution Cycle Membership

**Status:** Proposed, measurement-gated

**Current state:** `resolve_type_meta_list` traverses types while recursive meta
resolution scans `seen: List[Int]`. It ran 228,771 times in the retained
self-compile.
**Next action:** Measure seen-list depth and integer comparisons in a focused
meta-chain fixture; prefer a compact integer representation if admitted.
**Read first:** `blorp/src/compiler/stage_06_typecheck/type_system/context.brp`,
`blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/type_system/test_context.brp` plus a proposed meta-resolution chain probe.
**Decision:** Do not combine this automatically with string alias visitation;
integer meta IDs offer different, cheaper representations.

## Objective

Reduce recursive meta-cycle membership work without leaking visitation state
between branches or changing unbound-meta finalization.

## Why

Every type in a list can recurse through a chain of solved meta variables. A
linear `seen.contains(meta_id)` makes the path cost quadratic in chain depth.
The high call count is promising, but shallow chains favor the current list.

## Bounded experiment

Exercise solved chains, unresolved metas, self cycles, mutual cycles, repeated
metas in sibling types, and `finalize_unbound` both ways. Record:

```text
meta_resolution_requests
seen_membership_requests
seen_ids_compared
maximum_chain_depth
path_state_updates
allocations / releases
semantic_checksum
```

Compare the list with a small integer set, bitset, or generation-mark table
only at a boundary that gives stable, bounded meta IDs. A mutable table must be
strictly invocation-local and restore state on every branch; otherwise retain
value semantics.

## Invariants

- Unbound finalization produces the same type variables and names.
- Cycles terminate without hiding a valid solved value.
- Sibling traversals do not leak visited state.
- Tuple, function, tensor, result, and named-type recursion order is unchanged.
- No context mutation becomes observable outside the resolver.

## Acceptance and rejection

Admit only if realistic profiles show nontrivial chain depths or comparison
work. Accept if the deep fixture approaches one membership operation per meta,
improves deterministic instructions or allocations by at least 10%, preserves
all semantic checksums, and keeps shallow cases within 2%. Run the owning
suite and `scripts/compiler-check --stage typecheck`.

Reject if clearing/restoring an index costs as much as the scans, if state can
escape across branches, or if the improvement exists only at synthetic depths
not seen in compiler or package workloads.
