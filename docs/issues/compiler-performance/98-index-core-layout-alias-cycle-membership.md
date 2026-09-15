# Index Core Layout Alias-Cycle Membership

**Status:** Rejected after measurement

**Current state:** `resolve_types` walks every type and delegates to
`resolve_type`, which scans the path-local `seen_aliases: List[String]` before
following an alias. It ran 2,510,797 times in the retained self-compile.
**Decision:** Keep the ordered path list. The retained depth/width probe showed
that a path-local keyed membership companion removes scan work but increases
allocations and does not improve elapsed time, including on deep alias chains.
See
[`compiler_core_layout_alias_cycle_membership_2026-09-14.md`](../../../benchmarks/results/compiler_core_layout_alias_cycle_membership_2026-09-14.md).
**Retained benchmark:**
`benchmarks/compiler_core_layout_alias_cycle_profile plain list 50 256 24 4 reuse`
and the same command with `indexed`.
**Read first:** `blorp/src/compiler/stage_08_core_lower/list_layout.brp`,
`blorp/test/compiler/stage_08_core_lower/test_core_list_layout.brp`, the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md),
and the measurement result linked above.

## Objective

Reduce repeated alias-path membership work without changing Core layout
resolution, cycle termination, or branch-local visitation semantics.

## Why

The current shape is approximately:

```blorp
for typ in types:
	result = result.append(resolve_type(index, typ, seen_aliases))

if seen_aliases.contains(name):
	-- stop the cycle
else:
	resolve_type(index, alias, seen_aliases.append(name))
```

The structural analyzer reports `O(types * seen_aliases)`. The call count makes
this the most exposed screened candidate, but alias chains may normally be
short. Replacing a three-element list with a COW-updated dictionary could lose.

## Bounded experiment

Add a retained Core-layout fixture with independent controls for:

- root type count;
- alias-chain depth;
- repeated versus distinct alias names; and
- generic argument width.

Record alias-membership requests, names compared, recursive resolutions,
allocations/releases, and a checksum of resolved types. Keep fixture creation
outside the measured window. Label any new wrapper as a proposed benchmark
until its command is checked into `benchmarks/`.

Compare at least these representations without changing public Core types:

1. the existing ordered path list;
2. a path-local keyed membership companion; and
3. integer alias IDs plus a compact membership representation, only if the
   existing layout index already owns a stable ID boundary.

Do not infer identity from mangled names or silently make a shared mutable set.

## Invariants and tests

- Cycles terminate at exactly the same point.
- A name leaving one recursive branch is not visible in a sibling branch.
- Generic alias arguments are substituted in the same order.
- Non-cyclic aliases resolve to byte-identical Core.
- Unknown and malformed layout cases retain their current result.
- Value semantics and thread safety remain intact.

Add narrow acyclic, self-cycle, mutual-cycle, deep-chain, and sibling-branch
tests before the representation change. Inspect before/after dumped Core.

## Acceptance and rejection

Accept only if the focused wide/deep cases reduce membership comparisons to
near one lookup per request and improve either retired instructions or
allocations by at least 10%, with no material regression in the shallow case.
Then confirm the Stage 08 suite, `scripts/compiler-check --changed`, generated
Core identity, and a compiler self-compile.

Reject an index that increases shallow-case allocations materially, copies a
growing map at each recursion step, changes output, or moves ownership outside
the resolver merely to improve the probe. A well-measured conclusion that
real alias paths are too short is sufficient to close the issue without code.
