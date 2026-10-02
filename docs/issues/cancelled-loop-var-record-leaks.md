# A record `var` reassigned in a loop leaks when its task is cancelled

Status: open.

A task that reassigns a record `var` inside a loop and is cancelled while
parked in the same loop leaks the record and the lists it holds. The same
reassignment outside a loop, or a record bound once, is released.

```
func hold_then_sleep(seed: Int) -> Int:
	var table: Rows = { items = [seed], count = 1 }

	for i in 0..3:
		table = { table | count = table.count + i }
		sleep(10000)

	table.items.length()

-- cancel_after_parked_for_test(func(): hold_then_sleep(1))
```

## Evidence

`bin/blorp run --no-format --leak-check` on main 9e270d350:

| Shape | Result |
| --- | --- |
| record bound once, then `sleep` | 6 allocs, 6 releases |
| `var` reassigned once, then `sleep` | 6 allocs, 6 releases |
| `var` reassigned in a loop with `sleep` in the loop | 6 allocs, 4 releases, 2 leaked (88 bytes) |

The same holds for a table threaded through a tuple-returning call
(`(table, id) = table.intern(w)` in the loop): 4 objects leak. A record
handed to an impure consuming callee that parks before returning also leaks
when cancelled, but for a different reason: see
`consuming-clone-owned-parameter-has-no-cleanup-slot.md`.

## Suspected cause

The loop body's reassignment moves the slot's cancellation cleanup unit from
the old value to the new one, and the unit is not re-armed for the value
installed by the last completed iteration before the task parks. The planner
is `stage_09_core/cancellation_plan.brp`; see "Cancellation Cleanup Slots" in
`docs/OWNERSHIP_MODEL.md`.

## Tests

Add the loop shape to `blorp/test/runtime/memory/leak_check_baselines/` with
the fix, beside `let_alias_cancelled_sleep.brp`.
