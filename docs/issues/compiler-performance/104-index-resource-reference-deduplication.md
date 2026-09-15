# Index Resource-Reference Deduplication

**Status:** Proposed

**Current state:** `append_resource_refs` preserves an ordered list while every
element of `extra` scans the growing result with `contains`. It ran 210,048
times in the retained self-compile.
**Next action:** Add duplicate-density counters and compare an ordered-list plus
membership-index implementation.
**Read first:** `blorp/src/compiler/stage_06_typecheck/infer.brp`,
`blorp/test/compiler/stage_06_typecheck/test_infer.brp`, resource fixtures
under `blorp/test/compiler/stage_06_typecheck/`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_infer.brp` plus a proposed resource-reference merge probe.
**Decision:** Preserve first-occurrence order and current duplicate semantics;
ask before changing the containing inference result type.

## Objective

Make extra resource-reference admission near-linear while retaining the
ordered list as the semantic output.

## Why and proposed shape

```blorp
var result = refs
for name in extra:
	if not result.contains(name):
		result = result.append(name)
```

This is quadratic when many distinct names are appended. Keep the ordered list
as the output authority, but build a private membership set from `refs` and
update it alongside the list for accepted `extra` names. Do not return the set
or rely on dictionary iteration order.

The focused fixture should vary base width, extra width, duplicate ratio,
duplicate placement, and string length. Report membership requests, string
comparisons or hash probes, accepted names, list/set allocations and releases,
and an ordered output checksum. Include empty and all-duplicate controls.

## Invariants and tests

- Every original `refs` entry remains in place, including any pre-existing
  duplicates; only `extra` is conditionally admitted.
- First occurrence among `extra` wins.
- String equality semantics are unchanged.
- Empty inputs preserve their current allocation/value behavior where possible.
- Resource dependency order and diagnostics remain unchanged.

## Acceptance and rejection

Accept if distinct-name scaling becomes near-linear, the wide mixed-duplicate
fixture improves retired instructions or allocations by at least 10%, and
narrow/all-duplicate cases do not regress materially. Require the resource
fixtures, `scripts/compiler-check --stage typecheck`, leak-sensitive checks,
and the same inferred output.

Reject if building the set dominates observed production widths, if the output
is reconstructed from unordered storage, or if pre-existing duplicates are
silently normalized.
