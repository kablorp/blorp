# Stream Effective Method Type Parameters Into Admission

**Status:** Proposed; ownership-sensitive local refactor

**Current state:** `effective_method_type_parameters` concatenates discoveries
from parameter types, return type, and dimension constraints into a temporary
candidate list before feeding an existing dictionary-backed ordered admission
loop. The retained self-compile observed 273 invocations.
**Next action:** Add discovery-order/duplicate tests, then feed each discovered
batch directly into one owning admission frame.
**Read first:**
`blorp/src/compiler/stage_06_typecheck/headers/implementation_headers.brp`, the
type-parameter discovery helper, and
`blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp`.
**Fast loop:** Run the implementation-header suite and proposed high-discovery
production graph fixture.
**Decision:** Preserve explicit-before-implicit and first-discovery order. Reject
state threading that clones the dictionary or merely relocates candidate copies.

## Objective

Eliminate the temporary candidate list while retaining the existing ordered
result and name-admission policy.

## Proposed Shape

Keep `result` and `names` in `effective_method_type_parameters`' one owning
frame. A helper may inspect a discovered batch, but should return only the
updated result needed by that same frame:

```blorp
for param in decl.params:
	match param.type_expr:
		Some(type_expr):
			for candidate in discover_implicit_type_parameters_in_type(type_expr):
				-- apply the existing names/type-header admission rule here
		None: void
```

Repeat in the current order for return type, then every constraint's left and
right sides. Generated-C ownership or clone counters must prove `names` is not
copied across helper calls.

## Invariants And Scope

- Explicit method parameters remain before implicit parameters.
- Preserve first-discovery spans, duplicate handling, bounds, and `#` dimensions.
- Preserve implementation-parameter and declared-type-name exclusions.
- Cover duplicates across parameter/return/constraint positions, dimensions,
  empty signatures, and wide signatures.
- Do not alter method lookup, trait resolution, or header diagnostics.

## Measurement And Commands

Extend the proposed implementation phase fixture with parameter count,
occurrences per type, return-type occurrences, constraints, and duplicate ratio.
Measure production graph construction and report candidates discovered,
temporary items materialized, admission probes, clones, allocations,
instructions, elapsed time, and ordered header checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_implementation_headers.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when temporary candidate materialization falls to zero, a wide discovery
case improves instructions or allocations by at least 10%, a one-parameter
control stays within 3%, no new dictionary clone traffic appears, and headers
and diagnostics match. Reject if helper calls recreate COW copies, discovery
order changes, or the benefit exists only in a non-production model.
