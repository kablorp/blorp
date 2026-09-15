# Index Accepted-Alias Cycle Membership

**Status:** Proposed, measurement-gated

**Current state:** `resolve_alias_list` calls `resolve_alias_seen` for every
semantic type; every named type scans `seen: List[String]`. It ran 1,397,874
times in the retained self-compile.
**Next action:** Measure names compared per alias-resolution request on a
focused accepted-alias graph before choosing an index.
**Read first:**
`blorp/src/compiler/stage_06_typecheck/type_system/accepted_alias_authority.brp`,
`blorp/test/compiler/stage_06_typecheck/test_accepted_alias_authority.brp`, and
the [call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_06_typecheck/test_accepted_alias_authority.brp` plus a proposed alias-depth probe.
**Decision:** Keep this separate from Core layout alias resolution unless a
shared representation has measured wins in both owners.

## Objective

Reduce accepted-alias path membership work while preserving substitution,
cycle behavior, and branch isolation.

## Why

The current algorithm preserves a path-local list to detect recursive aliases:

```blorp
for typ in types:
	resolved = resolved.append(resolve_alias_seen(authority, seen, typ))

if seen.contains(name):
	typ
else:
	resolve_alias_seen(authority, seen.append(name), resolved_alias)
```

This is structurally `O(types * seen)`. The accepted authority also performs
substitution and preserves unresolved/cyclic values, so an apparently simple
global visited set would be incorrect.

## Bounded experiment

Create a fixture varying alias count, maximum chain depth, type-argument width,
and fan-out. Report:

```text
resolution_requests
alias_membership_requests
alias_names_compared
maximum_seen_depth
path_state_updates
allocations / releases
semantic_checksum
```

Start with the existing list. Compare a keyed path companion only after the
counter shows meaningful comparison work. If accepted aliases already have
stable definition IDs, test ID membership rather than introducing a second
string authority.

## Invariants and failure modes

- Preserve direct and mutual cycle behavior.
- Preserve substitution of generic parameters and dimensions.
- Never share branch-local visitation state across sibling type arguments.
- Preserve accepted-authority lookup errors and fallback types.
- Do not turn an immutable recursive value into shared mutable state.
- Account for the cost of building and COW-updating the index.

Tests must cover acyclic chains, self and mutual cycles, nested generic aliases,
repeated aliases in sibling arguments, and an unchanged non-alias type.

## Acceptance and rejection

Admit implementation only when comparison counts or profiler attribution show
at least 1% of the relevant accepted/type-resolution work. Accept a change
that reduces wide/deep deterministic work by at least 10%, keeps shallow inputs
within 2%, and preserves typed output and diagnostics. Run the owning suite,
`scripts/compiler-check --stage typecheck`, and the retained self-compile.

Reject if dictionary/set construction dominates, branch isolation becomes
implicit, or the change requires an unrelated accepted-authority redesign.
