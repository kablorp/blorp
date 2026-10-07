# Dict equality as a standard-library impl (2026-10-06)

Dict `==` used to be the runtime `blorp_dict_eq`, which compared stored values
as machine words. That was fast and right only for scalar values; a Dict of
tuples, records, lists or `Fixed` never equalled a copy of itself. It is now
`implements Equatable for Dict[K:Hashable, V:Equatable]` in
`standard_library/src/dict.brp`, which compares each value with its own `==`.
This records what the correct version costs for the case the old one already
handled, `Dict[Int, Int]`.

## Workload

Two `Dict[Int, Int]` of 100,000 equal entries, built before measurement and
compared 20 times (2,000,000 entry comparisons):

```
func build(n: Int, offset: Int) -> Dict[Int, Int]:
	var d: Dict[Int, Int] = {}
	var i: Int = 0

	while i < n:
		d = d.set(i + offset, i * 2)
		i += 1

	d


func main(args: List[String]):
	a: Dict[Int, Int] = build(100000, args.length() - 1)
	b: Dict[Int, Int] = build(100000, 0)
	var hits: Int = 0
	var r: Int = 0

	while r < 20:
		if a == b:
			hits += 1
		r += 1

	print(hits)
```

Allocations: the same program with `memory.reset_mem_stats()` before the loop
and `get_mem_stats().total_allocations` after it, run with
`bin/blorp run --no-format --memory-stats`. Instructions: `bin/blorp compile
--no-format -o x.c`, `clang -O2 -w x.c -lm -lpthread`, then `/usr/bin/time -l`,
three serial runs. A copy with `while r < 0` (dicts built, never compared)
retired 76M instructions; it is subtracted below. Apple clang 21, Apple
Silicon. Branch compiler `bin/blorp` FRESH on `fix/trait-default-methods`;
main compiler at `1df13d4b5`.

## Results

| Version | Allocations in the loop | Instructions, whole run | Per entry compared |
| --- | ---: | ---: | ---: |
| main, runtime `blorp_dict_eq` (wrong for managed values) | 6 (reviewer's count) | 194M | about 59 |
| impl iterating `for (key, value) in a` | 2,000,000 | 1,346M | about 635 |
| impl iterating `for key in a`, looking up `a.get(key)` and `b.get(key)` (landed) | 0 | 309M | about 117 |

The `(key, value)` loop boxes one tuple per entry. Iterating keys and looking
each value up in both dicts allocates nothing; the match on
`(a.get(key), b.get(key))` is scalar-replaced. It does one extra hash lookup
per entry, which is why it still costs about twice the old word comparison
for `Int` values.

## Known cost

The remaining 2x over the runtime routine for scalar values is the price of
dispatching value equality through `V`'s impl and of the second lookup. When
tuple scalar replacement lands (`docs/PRODUCT_UNIFICATION.md`, slice 3), the
`for (key, value) in a` loop should stop allocating, and the impl can return to
it and drop the lookup into `a`.
