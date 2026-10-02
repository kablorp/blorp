# A field moved into a `var` and grown in a loop copies

Status: open.

A record field read into a `var`, grown in a loop, and written back with a
record update copies the field on every call, even when the record is
uniquely owned.

```
pure func with_parent_over(family: NodeFamily, kind: Int, children: List[Int]) -> NodeFamily:
	first: Int = family.edges.length()
	var edges: List[Int] = family.edges

	for child in children:
		edges = edges.append(child)

	{ family |
		edges = edges,
		rows = family.rows.append(row_of(kind, first, children.length()))
	}
```

## Evidence

Probes `family_over_children` and `family_claims_sibling_list` (the
table-shape probe of the discovery data-model audit), allocations at
1,000 / 10,000 rows: 3,014 / 30,017 and 3,006 / 30,006, unchanged by the
nested-field hand-off.

## Cause

The hoisted field take (`take_hoisted_field_alias` in
`stage_09_core/reuse.brp`) moves a field into an immutable binding whose
straight-line body writes it back. A `var` binder and a loop between the read
and the write-back are both outside that proof, so `family.edges` stays
shared with `family` and the first append in the loop copies it.

## Proposed fix

Extend the take to a mutable binder initialized from the field when every
path from the binding reaches the update that replaces the field, the loop
body does not read the source's slot or the whole source, and nothing in the
window can leave early.
