# Condition reading a parameter blocks its alias move

Status: open.

`var out = b` followed by a condition that reads `b` copies the builder on
every call: the consumed parameter's alias move requires `b` to have no other
use, and the condition's read is one.

```
var out: DiscoveryBuilder = b
if b.nodes.length() % 2 == 0:
	out = out.append_node(row)
out = out.append_node_child(child)
out
```

## Evidence

- `blorp/test/test_compiler_new/tools/builder_rule_probe.brp`:
  `r1_p_cond_reads_builder` allocates 2006 / 20006 at 1,000 / 10,000 rows;
  `r1_p_cond_reads_out` (the condition reads `out`) is flat at 15 / 19.
- `move_only_owner_alias` in
  `blorp/src/compiler/stage_09_core/perceus/short_circuit.brp` rejects the
  move when the census finds any other reference to the owner.

## Proposed fix

Let the move tolerate borrows of the owner that complete before the alias's
first ownership event on every path (here, the condition), or rewrite such
reads to read the alias, which holds the same value until its first update.
