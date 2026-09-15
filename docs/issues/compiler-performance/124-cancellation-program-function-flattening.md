# Flatten Cancellation Program Functions Without Prefix Copies

**Status:** Proposed; implementation and measurement ready

**Current state:** `cancellation_plan.program_functions` appends ordinary
functions but concatenates each implementation's method list into the growing
result.
**Next action:** Add an interleaved declaration-order test and a production
`analyze_program_cancellation` benchmark; append methods individually only if
the current concat exhibits growing-prefix work.
**Read first:** `blorp/src/compiler/stage_10_backend/cancellation_plan.brp` and
`blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp`.
**Fast loop:** Run the cancellation-plan suite plus a proposed program-function
flattening profile.
**Decision:** Preserve exact declaration/method order and function identity;
do not redesign cancellation planning.

## Objective

Make program-function flattening linear in the number of functions and methods.

## Proposed Shape

```blorp
for decl in program.decls:
	match decl:
		FunctionDecl(function): functions = functions.append(function)
		ImplDecl(implementation):
			for method in implementation.methods:
				functions = functions.append(method)
		_: void
```

Do not use `flat_map` unless generated C and allocation measurements show it
retains the same single-owner behavior. The existing cancellation-plan profile
runs `analyze_program_cancellation`—including `program_functions`—before its
measured plan-construction window, so it is not acceptance evidence for this
helper.

## Invariants And Tests

- Preserve top-level declaration order and method order within each impl.
- Preserve duplicate names and distinct definition IDs; this function is not a
  deduplication boundary.
- Exclude the same non-function declaration variants as today.
- Cover empty, function-only, impl-only, and interleaved programs.
- Downstream callable/cancellation identities and generated C must match.

## Feedback Loop

Use a proposed fixture that times the actual `analyze_program_cancellation`
call while varying declaration count, implementations, and methods per
implementation. Record functions emitted, copied-prefix elements,
allocations/releases, retired instructions, elapsed time, ordered identity
checksum, and cancellation-summary checksum.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_10_backend/test_cancellation_plan.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize leak
```

## Acceptance And Rejection

Accept when demonstrated prefix transfers fall by at least 80%, a
many-implementation/few-methods fixture improves instructions or allocations
by at least 10%, a one-implementation/many-methods concat control and a small
case stay within 2%, and cancellation plans/C output match. Reject if baseline
concat is already amortized, the list is not uniquely owned, order changes, or
the benchmark still opens its measured window after this helper runs.
