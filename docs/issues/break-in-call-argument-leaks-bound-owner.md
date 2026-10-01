# Break or continue inside a call argument leaks a bound owner

Status: open.

Leaving a loop iteration with `break` or `continue` from inside a call
argument leaks an owned local bound earlier in the iteration.

```
for i in 0..count:
	appended: Tables = out.append_row(i)
	out = appended.append_other(
		match i == 2:
			True:
				break
				0
			False:
				i
	)
```

## Evidence

- `bin/blorp run --leak-check` on this shape reports 6 leaked objects
  (`Tables`, `List` and their buffers) on main at 5ef19a6ca and on
  `core/builder-handoff-gaps`; values are correct.
- `blorp/test/runtime/functions/test_loop_temporary_leaving_early.brp` checks
  the values of this shape outside the leak gate because of this leak; move
  it to `blorp/test/runtime/memory/` once the leak is fixed.
- Suspected cause: Perceus balances the let's owner after the assignment, and
  the early exit inside the argument skips that release.
