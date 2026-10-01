# A builder captured by a closure or stored in a record copies

Status: open.

A builder that a closure captures, or that a record holds in a field, is
referenced twice for as long as the closure or record lives, so every update
of the builder copies it and the tables appended to meanwhile. The closure
case copies even when the closure is called once and dead afterwards.

```
size: pure () -> Int = pure func() -> Int: b.nodes.length()
n: Int = size()
b.append_node(row_at(n))
```

```
holder: Holder = {held = b, tag = i}
holder.held.append_node(row_at(holder.tag))
```

## Evidence

`blorp/test/compiler_new/tools/builder_rule_probe.brp`, allocations at 500 /
2,000 rows: `r7_p_closure_dead` 1505 / 6005 and `r7_p_stored_in_record` 1505 /
6005. A builder bound to a second name that is dead after one use
(`r7_p_alias_dead`) and an alias followed by an update
(`r7_p_alias_then_update`) are flat.

## Proposed fix

A closure that only reads a captured value could capture the read value, or a
borrow, instead of the owner; a record built from a consumed value could take
it by move when the value's last use is the construction.

Tests: the probe shapes as rows of
`blorp/test/runtime/fixture/consume_owned_threading_shapes.brp`.
