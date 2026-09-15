# Reduce Standard-Inline Rename Copying

**Status:** Proposed, measurement-gated

**Current state:** `clone_expr` carries `List[StdInlineRename]` through the
expression tree. `rename_binder` prepends with `[rename].concat(renames)`, and
`renamed_var` linearly scans the list. `clone_expr` ran 101,279 times in the
retained self-compile.
**Next action:** Measure rename depth, copied entries, and lookup comparisons on
wide and deeply nested inline bodies.
**Read first:** `blorp/src/compiler/stage_09_core/std_inline.brp`,
`blorp/test/compiler/stage_09_core/test_core_std_inline.brp`, and the
[call-count screen](../../../benchmarks/results/compiler_complexity_call_counts_2026-09-14.md).
**Fast loop:** `bin/blorp test blorp/test/compiler/stage_09_core/test_core_std_inline.brp`.
Add a nested-binder `compiler_std_inline_rename_profile` probe before changing
the representation.
**Decision:** Preserve exact `CoreVar` identity and branch-local scope. Do not
fold this into a general Core environment abstraction without evidence.

## Objective

Reduce rename-path copying and lookup comparisons during standard inlining
without changing fresh identities or lexical scope.

## Why

```blorp
private pure func renamed_var(renames, variable) -> CoreVar:
	for rename in renames:
		if core_vars_equal(rename.original, variable):
			return rename.replacement

private pure func rename_binder(next_id, renames, variable):
	[rename].concat(renames)
```

Every binder can copy its ancestor rename path, and every variable reference
can scan that path. Lambda parameters and concurrent bindings build several
renames before cloning a body.

## Bounded experiment

Create retained fixtures varying binder depth, bindings per block, variable
references, shadowing frequency, and sibling branches. Record rename entries
copied, lookup comparisons, maximum active depth, path-state allocations,
cloned nodes, next-ID checksum, and exact Core checksum.

Compare:

- the current nearest-first list;
- batched prefix construction for multi-binder forms; and
- a path-local exact-identity index with explicit scope restoration.

Do not key only by source name: `CoreVar` identity includes uniqueness and
definition identity. A mutable index must restore shadowed mappings on every
branch and early return.

## Invariants and tests

- Fresh IDs and renamed `CoreVar` values are identical.
- Nearest shadowing wins.
- Sibling and timeout expressions see exactly their current rename scope.
- Captures, patterns, select arms, concurrency bindings, and lambdas retain
  current ownership and ordering.
- Dumped Core passes invariants and should be byte-identical for the focused
  fixtures.

## Acceptance and rejection

Accept if deep/wide deterministic copy/comparison work falls by at least 25%
and instructions or allocations improve by at least 10%, with no shallow-case
regression above 2%. Run the standard-inline suite,
`scripts/compiler-check --changed`, `--check-invariants`, and relevant Core
sanitizers.

Reject any representation with ambiguous identity, leaked branch state, a
second unsynchronized authority, or a gain only at unrealistic nesting depth.
