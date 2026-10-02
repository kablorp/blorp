# Discovery redesign: allocation probes and node census, 2026-10-01

Measurements behind `docs/DISCOVERY_REDESIGN.md` (sections 7 and the
appendices). They estimate what typed syntax trees and tuple-returning parse
functions cost on today's compiler; they are inputs to a design, not a change.

## Provenance

- Revision: origin/main `519e7311c`; `bin/blorp` built from it with `make`
- Host: Apple Silicon, Darwin 25.6.0; Apple clang 21.0.0
- Probes: `bin/blorp run --release --no-format --memory-stats <probe>.brp`,
  10,000 values each, every value kept in a list so nothing is freed early
- Census: `bin/blorp run --release --no-format census.brp -- blorp/src/main.brp`
  from the repository root (the tool must sit in `blorp/test/compiler_new/tools/`
  for its relative imports; it was run there and removed)
- No gate was running

## Results

| Shape | Allocations per value |
| --- | ---: |
| payload-free variant | 0 (13 per 10,000: list growth) |
| variant with three `Int` payloads | 1 |
| variant with a struct and an `Int` payload | 2 (the struct is boxed) |
| variant whose payload is a record holding an empty list and a 1-allocation child | 3 |
| the same record holding a two-element list of payload-free leaves | 3 |
| variant with two payload-free children and two `Int`s | 1 |
| record holding `Some(Int)`, or `None` | 1 (the record only) |
| variant holding `Some(existing node)`, or `None` | 1 |
| variant holding `Some(new record)` | 2 |
| `(state, leaf)` returned and destructured, the leaf a two-field record | 4 (leaf 1, overhead 3) |
| two nested `(state, leaf)` calls, one leaf kept | 9 |
| `(state, value)` where the state holds a growing `List[Int]` | 3 per call, linear |

The growing-list probe finishes 200,000 calls in no measurable time, so the
state's list is not copied per call; the overhead is a fixed tuple and a state
record per call.

Census of the self-compile inputs (`blorp/src/main.brp`, prelude and tuple):
449 modules, 32,098 definitions, 35,443 parameters, 902 type parameters,
954,978 nodes, 874,344 child edges, 162,465 name-span rows. Counts by node kind
are in the design document's Appendix A.

## Probe programs

### `union_cost_probe.brp`

```blorp
-- How many allocations each tree-node shape costs, per value kept in a list.
import:
	memory: MemStats, get_mem_stats, mem_delta

struct Spot {
	span: Int,
	id: Int
}

record CallParts {
	callee: Node,
	arguments: List[Node],
	span: Int,
	id: Int
}

union Node:
	Leaf
	Name(Int, Int, Int)
	Spotted(Spot, Int)
	Call(CallParts)
	Pair(Node, Node, Int, Int)


record Holder {
	value: Option[Int]
}


N: Int = 10000


func report(label: String, before: MemStats):
	after: MemStats = get_mem_stats()
	delta: MemStats = mem_delta(before, after)
	print("${label}: ${delta.total_allocations} allocations for ${N}")


func main(args: List[String]) -> Int:
	var b0: MemStats = get_mem_stats()
	var leaves: List[Node] = []
	for i in 0..N:
		leaves = leaves.append(Leaf)
	report("payload-free variant", b0)

	b0 = get_mem_stats()
	var names: List[Node] = []
	for i in 0..N:
		names = names.append(Name(i, i + 1, i + 2))
	report("three-Int variant", b0)

	b0 = get_mem_stats()
	var spotted: List[Node] = []
	for i in 0..N:
		spotted = spotted.append(Spotted({span = i, id = i}, i))
	report("struct+Int variant", b0)

	b0 = get_mem_stats()
	var calls: List[Node] = []
	for i in 0..N:
		calls = calls.append(Call({callee = Name(i, i, i), arguments = [], span = i, id = i}))
	report("record variant with empty list and a Name child", b0)

	b0 = get_mem_stats()
	var calls2: List[Node] = []
	for i in 0..N:
		calls2 = calls2.append(Call({callee = Leaf, arguments = [Leaf, Leaf], span = i, id = i}))
	report("record variant with a two-element list of leaves", b0)

	b0 = get_mem_stats()
	var pairs: List[Node] = []
	for i in 0..N:
		pairs = pairs.append(Pair(Leaf, Leaf, i, i))
	report("two-child positional variant of leaves", b0)

	b0 = get_mem_stats()
	var holders: List[Holder] = []
	for i in 0..N:
		holders = holders.append({value = Some(i)})
	report("record holding Some(Int)", b0)

	b0 = get_mem_stats()
	var nones: List[Holder] = []
	for i in 0..N:
		nones = nones.append({value = None})
	report("record holding None", b0)

	print("${leaves.length() + names.length() + spotted.length() + calls.length() + calls2.length() + pairs.length() + holders.length() + nones.length()}")
	0
```

### `option_cost_probe.brp`

```blorp
import:
	memory: MemStats, get_mem_stats, mem_delta

record Parts {
	a: Int,
	b: Int
}

union Node:
	Leaf
	Name(Int)
	WithOptional(Option[Node], Int)
	WithParts(Option[Parts], Int)

record Holder {
	child: Option[Node]
}

N: Int = 10000

func report(label: String, before: MemStats):
	after: MemStats = get_mem_stats()
	delta: MemStats = mem_delta(before, after)
	print("${label}: ${delta.total_allocations} allocations for ${N}")

func main(args: List[String]) -> Int:
	shared: Node = Name(7)
	var b0: MemStats = get_mem_stats()
	var xs: List[Node] = []
	for i in 0..N:
		xs = xs.append(WithOptional(Some(shared), i))
	report("variant with Some(existing node)", b0)

	b0 = get_mem_stats()
	var ys: List[Node] = []
	for i in 0..N:
		ys = ys.append(WithOptional(None, i))
	report("variant with None", b0)

	b0 = get_mem_stats()
	var hs: List[Holder] = []
	for i in 0..N:
		hs = hs.append({child = Some(shared)})
	report("record with Some(existing node)", b0)

	b0 = get_mem_stats()
	var ps: List[Node] = []
	for i in 0..N:
		ps = ps.append(WithParts(Some({a = i, b = i}), i))
	report("variant with Some(new record)", b0)
	print("${xs.length() + ys.length() + hs.length() + ps.length()}")
	0
```

### `tuple_return_probe.brp`

```blorp
-- Allocations of a parser-shaped call that returns (state, value).
import:
	memory: MemStats, get_mem_stats, mem_delta

struct Counters {
	expressions: Int,
	names: Int
}

record ParseState {
	cursor: Int,
	counters: Counters,
	diagnostics: List[String]
}

record Leaf {
	id: Int,
	span: Int
}

N: Int = 10000


pure func advanced(state: ParseState) -> ParseState:
	next: Int = state.cursor + 1
	{ state | cursor = next }


pure func parse_leaf(state: ParseState) -> (ParseState, Leaf):
	id: Int = state.counters.expressions
	span: Int = state.cursor
	counters: Counters = { state.counters | expressions = id + 1 }
	after: ParseState = { state | counters = counters }
	leaf: Leaf = {id = id, span = span}
	(after.advanced(), leaf)


pure func parse_leaf_twice(state: ParseState) -> (ParseState, Leaf):
	(first_state, first) = parse_leaf(state)
	(second_state, _) = parse_leaf(first_state)
	(second_state, first)


pure func advance_only(state: ParseState) -> ParseState:
	state.advanced()


func report(label: String, before: MemStats):
	after: MemStats = get_mem_stats()
	delta: MemStats = mem_delta(before, after)
	print("${label}: ${delta.total_allocations} allocations for ${N}")


func main(args: List[String]) -> Int:
	var state: ParseState = {cursor = 0, counters = {expressions = 0, names = 0}, diagnostics = []}
	var b0: MemStats = get_mem_stats()
	for i in 0..N:
		state = state.advance_only()
	report("state update only", b0)

	b0 = get_mem_stats()
	var leaves: List[Leaf] = []
	for i in 0..N:
		(next, leaf) = parse_leaf(state)
		state = next
		leaves = leaves.append(leaf)
	report("tuple return, leaf kept", b0)

	b0 = get_mem_stats()
	for i in 0..N:
		(next, leaf) = parse_leaf_twice(state)
		state = next
		leaves = leaves.append(leaf)
	report("two nested tuple returns, one leaf kept", b0)
	print("${leaves.length()} ${state.cursor}")
	0
```

### `tuple_state_list_probe.brp`

Run with the call count as its argument (`-- 200000`); with `--memory-stats`
it prints allocations.

```blorp
-- Does a list held in a tuple-returned parse state copy on each append?
import:
	memory: MemStats, get_mem_stats, mem_delta

record ParseState {
	cursor: Int,
	definitions: List[Int]
}


pure func define(state: ParseState, value: Int) -> (ParseState, Int):
	next: Int = state.cursor + 1
	grown: List[Int] = state.definitions.append(value)
	({ state | cursor = next, definitions = grown }, value)


func run(n: Int):
	var state: ParseState = {cursor = 0, definitions = []}
	before: MemStats = get_mem_stats()
	var total: Int = 0
	for i in 0..n:
		(next, value) = define(state, i)
		state = next
		total += value
	after: MemStats = get_mem_stats()
	delta: MemStats = mem_delta(before, after)
	print("n=${n}: ${delta.total_allocations} allocations (${state.definitions.length()} rows, ${total})")


func main(args: List[String]) -> Int:
	n: Int = args.get(1).get_or("1000").parse_int().get_or(1000)
	run(n)
	0
```

### `census.brp`

```blorp
-- Node counts by kind over one discovery run of the given roots.
import:
	../../../src/compiler_new/stage_01_discovery/pipeline:
		compiler_implicit_modules,
		discover,
	../../../src/compiler_new/stage_01_discovery/sources/source_provider:
		FILE_SYSTEM_SOURCE_PROVIDER,
		SourceLookupRoots,
	../../../src/compiler_new/stage_01_discovery/tables/frontend_tables:
		FreezeOutcome(FrozenTables, TableInvariantsViolated),
		node_count,
		node_row_at,
		node_name_span_count,
		module_count,
		definition_count,
		parameter_count,
		type_parameter_count,
	../../../src/compiler_new/stage_01_discovery/tables/row_kinds: node_kind_name


LOOKUP_ROOTS: SourceLookupRoots = {
	standard_library_root = "standard_library/src",
	native_package_roots = ["pkg"],
	source_packages = []
}


func main(args: List[String]) -> Int:
	roots: List[String] = args.drop(1)
	outcome: FreezeOutcome = discover(
		FILE_SYSTEM_SOURCE_PROVIDER,
		LOOKUP_ROOTS,
		roots,
		compiler_implicit_modules(),
	)

	match outcome:
		FrozenTables(tables):
			var counts: Dict[String, Int] = {}
			var edges: Int = 0
			var index: Int = 0
			total: Int = tables.node_count()

			while index < total:
				match tables.node_row_at(index):
					Some(row):
						name: String = row.kind.node_kind_name()
						counts = counts.set(name, counts.get(name).get_or(0) + 1)
						edges += row.children.count
					None:
						edges += 0
				index += 1

			print("modules ${tables.module_count()} definitions ${tables.definition_count()} parameters ${tables.parameter_count()} type_parameters ${tables.type_parameter_count()}")
			print("nodes ${total} edges ${edges} name_spans ${tables.node_name_span_count()}")

			for key in counts.keys():
				print("${key} ${counts.get(key).get_or(0)}")

			0
		TableInvariantsViolated(_):
			print("violated")
			1
```
