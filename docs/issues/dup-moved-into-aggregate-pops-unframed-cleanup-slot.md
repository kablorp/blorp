# A retained value moved into a list pops a cleanup slot that was never pushed

Status: open.

Inside a task, `[x]` where `x` is a Perceus-retained borrowed local emits
`blorp_task_cleanup_pop_slot_with_task(&x, ...)` after the list construction,
although `x` has no cleanup frame. The call is a no-op today (seen at 15 sites
in the self-compile C), but if `x` ever gains a frame the pop would drop its
cancellation cleanup while the owner still holds the reference. The planner
should pop a slot only for a move out of a tracked local, not for a `DupExpr`
copy.
