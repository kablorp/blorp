# A builder read after it was handed on, or declared in an arm, copies

Status: open.

Two shapes keep a second reference to a builder that is handed on, so the next
update copies the builder record and every table appended to meanwhile.

**Read after hand-off.** The builder is read in a later statement, even
though the call that consumed it only bound its result to a new name:

```
handed: DiscoveryBuilder = b.append_node(row)
n: Int = b.nodes.length()
handed.append_node(row_at(n))
```

Reading first is flat. This is the same cause as
`alias-move-blocked-by-condition-read.md`, which is the condition-after-alias
form of it.

**`var` declared in an arm.** One arm hands the builder on directly and the
other declares a `var` from it and updates it in a loop:

```
if c:
	b.append_node(row)
else:
	var out: DiscoveryBuilder = b

	for k in 0..2:
		out = out.append_node(row)

	out
```

Declaring `var out = b` before the branch and branching on `out` is flat.

## Evidence

`blorp/test/compiler_new/tools/builder_rule_probe.brp`, allocations at 500 /
2,000 rows:

| Shape | Allocations |
| --- | --- |
| `read_after_handoff` | 1005 / 4005 |
| `read_before_handoff` (control) | 14 / 16 |
| `var_declared_in_arm` | 510 / 2011 |

A reproduction in the parser: reading a child mark from `builder` after
`advanced = builder.advance_token()` made parsing a `with ... on` header copy
the tables once per statement; taking the mark first removed it.

## Proposed fix

As for the condition read: let a hand-off tolerate reads of the owner that
complete before the new binding's first ownership event, or rewrite such reads
to read the new binding, which holds the same value until its first update.
For the arm case, join the two arms' ownership of the parameter instead of
keeping it shared.

Tests: the probe shapes as rows of
`blorp/test/runtime/fixture/consume_owned_threading_shapes.brp`.
