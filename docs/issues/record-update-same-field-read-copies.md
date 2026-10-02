# Record update that reads the field it replaces copies

Status: open.

A record update whose replacement reads the slot it takes, or a slot taken
by an earlier replacement, copies the field on every update instead of
updating it in place. This is builder threading rule 6.

```
{ b | nodes = b.nodes.append(row(b.nodes.length())) }
{ b | node_children = b.node_children.append(id(b.nodes.length())), nodes = b.nodes.append(r) }
```

## Evidence

- `blorp/test/compiler_new/tools/builder_rule_probe.brp`:
  `r6_p_scalar_then_list_same_field` allocates 1005 / 10005 at 1,000 / 10,000
  rows and `r6_p_other_field_list` 1014 / 10018. The workaround
  `r6_w_locals` (read the length into a local first) is flat.
- `take_self_consumed_record_fields` / `take_self_consumed_cow_fields` in
  `blorp/src/compiler/stage_09_core/reuse.brp` only take a field with
  `CowFieldTakeRetainPolicy` when the owned alias is the only read of the
  slot across every replacement (`touches == 1`).
- Relaxing that count alone is unsound. Arguments are evaluated left to right
  with the receiver first, and replacements run in declaration order
  (`nodes` before `node_children` in `DiscoveryBuilder`), so in both shapes
  the `b.nodes.length()` read runs after the take has emptied the slot.

A nested update of a field reads its own base path through the binding
lowering makes for the base, so `{ p | state = { p.state | cursor =
p.state.cursor + 1 } }` no longer counts as a second read of `state`. Reads of
a replaced slot in another replacement, as in the shapes above, still copy.

## Proposed split

1. A pre-Perceus rewrite that evaluates a call's later arguments before its
   receiver when the receiver is `base.field` on the immutable
   `__record_update` binding: the field read is pure, so its position does not
   matter, and the later arguments keep their relative order. Hoisting a read
   out of a later replacement to before an earlier one also needs the moved
   expression to be pure.
2. A position-aware extension of the take proof in `reuse.brp`: accept
   same-slot reads that complete before the take on the straight-line spine
   and yield no alias of the slot (an operator or primitive result), and keep
   rejecting reads after it.

Tests: the probe shapes as rows of
`blorp/test/runtime/fixture/consume_owned_threading_shapes.brp`, and
value-semantics cases where the read value is checked.
