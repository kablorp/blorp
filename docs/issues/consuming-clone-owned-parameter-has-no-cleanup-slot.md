# A consuming clone's owned parameter has no cancellation cleanup slot

Status: open.

When a call hands a record to a consuming clone, the caller pops its own
cancellation cleanup unit for the argument (the argument's reference went to
the callee). The clone owns the parameter from then on, but nothing gives the
parameter a cleanup slot. If the clone parks and its task is cancelled, no
one releases the record.

## Reproduction

`bin/blorp run --no-format --leak-check` on main 9e270d350 and on
`core/nested-field-update-in-place`: 6 allocs, 4 releases, 2 leaked
(88 bytes), the record and its list.

```
import:
	test: cancel_after_parked_for_test


record Table {
	items: List[Int],
	count: Int
}


func grow(t: Table, x: Int) -> Table:
	n: Int = t.count
	sleep(10000)
	{ t | items = t.items.append(x), count = n + 1 }


func hold(seed: Int) -> Int:
	var table: Table = { items = [seed], count = 1 }
	var spin: Int = 0

	for i in 0..2:
		spin += i

	table = table.grow(spin)
	table.items.length()


func main(args: List[String]) -> Int:
	if cancel_after_parked_for_test(func(): hold(1)):
		print("cancelled")
		0
	else:
		1
```

Two more shapes leak the same way once tuple-returning functions get
consuming clones (the parked branch `core/tuple-return-handoff`), and are
clean without it:

- the same callee returning `(Table, Int)`, called as
  `(next, id) = table.intern(spin)` then `table = next`;
- a builder method `intern_name(b: Builder, x) -> (Builder, Int)` that moves
  `b.names` through such a callee and back.

## Proposed fix

Give a consuming clone's owned parameter a cleanup slot at entry, as a
`let`-bound owner gets one (`stage_09_core/cancellation_plan.brp`, "Cancellation
Cleanup Slots" in `docs/OWNERSHIP_MODEL.md`), popped wherever the clone hands
the parameter on or returns it.

## Tests

The reproduction above, and the two tuple shapes, as rows of
`blorp/test/runtime/memory/leak_check_baselines/` beside
`let_alias_cancelled_sleep.brp`.
