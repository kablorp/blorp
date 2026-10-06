# A caller pushes a cleanup slot it pops again before handing the value over

Status: open.

A local whose last use hands it to a consuming user call gets a
cancellation cleanup slot, and the caller pops that slot right before the
call. When no cancellation point falls between the local's binding and the
call, the push and the pop protect nothing:

```c
blorp_task_cleanup_push_with_task(&__blorp_cleanup_payload, &payload, ...);
blorp_task_cleanup_pop_slot_with_task(&payload, __blorp_task);
return owned_parameter_store_after_sleep(payload);
```

`cancellation_call_argument_has_entry_handoff` in
`stage_09_core/cancellation_plan.brp` answers False for every `UserCall`, so
the planner does not count the call as handing the reference on before a
cancellation point, and the local stays tracked.

## Proposed change

Answer True for a `UserCall`'s consumed arguments. The precondition holds
now: a callee that owns a handed-over parameter pushes its own slot at entry
whenever it can be cancelled before letting go of it ("Cancellation Cleanup
Slots" in `docs/OWNERSHIP_MODEL.md`), and the final-Core invariant
`DisagreeingUserCallContract` makes every call of one callee hand over the
same arguments.

## Tests

An emit pin that a local bound and handed to a consuming call with no
cancellation point in between has no cleanup frame, and the
`consuming_clone_*` leak baselines in
`blorp/test/test_runtime/test_memory/leak_check_baselines/` unchanged. Measure the
stage-2 self-compile at `-O0` and `-O2`.
