# Chained updates of a conditionally reassigned `var` copy

Status: open.

A chain (`out.f().g()`), a tail `if` or `match` whose arms call on the
variable, or a call result bound to a new name (`x = out.f()`) copies the
builder on every call when the receiver is a `var` that is also reassigned
under an `if`, a `match` or a loop. The same shapes are flat when the receiver
is a parameter or a binding that is never reassigned, and a single tail call
(`out.f()`) is flat even on such a `var`.

```
var out: DiscoveryBuilder = b.append_node(row)

if c:
	out = out.append_node(row)

out
	.append_node_child(child)
	.append_node(row)
```

## Evidence

`blorp/test/compiler_new/tools/builder_rule_probe.brp`, allocations at 500 /
2,000 rows:

| Shape | Allocations | Reads as |
| --- | --- | --- |
| `chain_tail_after_if` | 1510 / 6012 | the example above |
| `chain_tail_after_loop` | 1515 / 6017 | the same after a loop |
| `chain_assigned_after_arm` | 1512 / 6014 | `out = out.f().g()` after an `if` |
| `chain_in_arm` | 763 / 3014 | `if c: out = out.f().g()` then `out.h()` |
| `cond_tail_on_var` | 514 / 2016 | `if d: out.f() else: out` after an `if` |
| `bound_call_on_conditional_var` | 1510 / 6012 | `x = out.f()` then `x.g()` |

Flat controls: `chain_assigned_to_var`, `chain_declared_var`,
`chain_declared_then_arm` (the chain starts at a parameter),
`chain_arm_value` and `cond_tail_on_unconditional_var` (the var is never
reassigned under a branch), and `r2_p_tail_after_if` (one tail call).

A parser that chains these shapes shows in the allocation budget: a copy per
repeat makes `parsing repeated ... copies no table` fail for its construct.

## Proposed fix

The var's ownership at the join of two branches is probably summarized as
possibly shared, so the next consuming use that is not a plain single tail
keeps a reference. Treat a `var` that every incoming path owns uniquely as
owned at the join, as the single-tail-call case already is.

Tests: the shapes above as rows of
`blorp/test/runtime/fixture/consume_owned_threading_shapes.brp`.
