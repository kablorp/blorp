# Index Global Initializer Dependency Admission

**Status:** Proposed; bounded graph-construction refactor

**Current state:** `global_initializer_dependencies` scans its growing ordered
dependency-row list for every resolved free reference. The retained self-compile
observed 1,053 invocations.
**Next action:** Add duplicate and cross-module identity tests, then maintain a
local header-row membership dictionary beside the ordered result.
**Read first:**
`blorp/src/compiler/stage_06_typecheck/headers/global_header_completion.brp`
and `blorp/test/compiler/pipeline/test_global_header_completion.brp`.
**Fast loop:** Run that owning suite plus the proposed repeated-reference mode
of the typecheck phase profile.
**Decision:** The dictionary is invocation-local and header-row keyed; ask for
guidance before changing dependency identity, order, or graph representation.

## Objective

Build an initializer's unique dependency rows in linear expected work while
retaining exact first-reference order.

## Proposed Shape

```blorp
match resolved_global_reference(...):
	Some(dependency_row):
		if not seen_dependencies.contains(dependency_row):
			seen_dependencies = seen_dependencies.set(dependency_row, True)
			dependencies = dependencies.append(dependency_row)
	None:
		void
```

Use the resolved header row as the current nominal identity; do not key by
display spelling. Construct the dictionary once per initializer, not once per
reference, and retain the ordered list as the graph authority.

## Invariants And Scope

- Repeated references to one global produce one edge at its first position.
- Same-named globals from different modules remain distinct.
- Preserve missing, ambiguous, local, imported, qualified, and cyclic behavior.
- Preserve topological/SCC results and diagnostic order.
- Do not change free-reference discovery, name resolution, or the graph model.

## Feedback Loop

Extend the proposed production phase fixture with initializer count, references
per initializer, duplicate ratio, modules, and fan-in as independent axes.
Record reference visits, list comparisons, dictionary probes, accepted rows,
allocations/releases, instructions, elapsed time, and ordered graph checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/pipeline/test_global_header_completion.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when growing-list comparisons fall by at least 90%, the wide repeated
reference case improves instructions or allocations by at least 10%, a small
initializer remains within 3%, and dependency/diagnostic output is identical.
Reject if the index is rebuilt per reference, row identity is weakened, or
equivalent work moves into another graph phase.
