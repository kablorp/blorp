# Accumulate Static Storage Names Once

**Status:** Proposed; implementation and measurement ready

**Current state:** `c_symbol_projection.static_storage_names` recursively
returns child name lists and concatenates them into a growing prefix for record,
list, tuple, and union constants.
**Next action:** Add an all-constructor preorder test and production
symbol-projection benchmark, then thread one ordered accumulator only if wide
or deep fixtures demonstrate recursive copying.
**Read first:** `blorp/src/compiler/stage_10_backend/c_symbol_projection.brp`,
`blorp/src/compiler/stage_10_backend/c_naming.brp`, and
`blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp`.
**Fast loop:** Run the symbol-projection suite plus a proposed nested-static
storage profile.
**Decision:** Preserve exact path/name order; do not change callable symbol
projection or static-storage naming rules.

## Objective

Make static-storage name collection linear in the number of nested static
constructs while retaining deterministic names.

## Proposed Shape

```blorp
private pure func append_static_storage_names(
	names: List[String], path: String, expr: CoreExpr,
) -> List[String]:
	-- append the current construct name, then recurse into children in order
```

Seed once from `program_symbol_inventory`. Keep path derivation at the same
node and index as today. Do not introduce a dictionary: duplicates, if any,
belong to later symbol validation and must not be silently removed here. Verify
in generated C or allocation counters that recursive calls keep the accumulator
uniquely writable.

## Invariants And Tests

- Preserve preorder and all record field/list/tuple/union child path spellings.
- Preserve tuple element filtering and child indices, including void elements.
- Non-static expressions contribute no names.
- Duplicate/collision detection receives the identical ordered input.
- Cover every supported construct, deep mixed nesting, siblings, empty
  aggregates, and non-static leaves.

## Feedback Loop

Add a proposed fixture varying nesting depth, branch width, and construct kind
around the actual `project_core_program_callables` boundary. Record nodes,
names, modeled recursive transfers, allocations/releases, retired instructions,
elapsed time, ordered name checksum, and projected-program checksum. Existing
symbol-projection benchmark modes do not isolate nested static globals.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_10_backend/test_c_symbol_projection.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

Inspect generated C for a deeply nested static aggregate.

## Acceptance And Rejection

Accept when demonstrated recursive transfers fall by at least 80%, wide and
deep inputs each improve instructions or allocations by at least 10%, a
shallow control stays within 2%, and symbol inventory/C hashes match. Reject if
baseline scaling is already aggregate-linear, path order changes, duplicates
disappear early, or recursive calls retain the accumulator and force equivalent
COW copying.
