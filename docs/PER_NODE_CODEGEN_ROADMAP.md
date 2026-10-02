# Per-Node Codegen Roadmap

The self-compile spends thousands of retired instructions per Core node per
pass where a hand-written C compiler pass spends tens. The gap is not in what
the passes compute; it is in what the generated C does around every node:
reference counting, cancellation cleanup frames, out-of-line runtime calls and
uniqueness tests. This roadmap holds the open work that attacks that per-node
cost. Every item here changes the generated C on purpose, so the oracle is
behavioral (suites, leak and sanitizer gates, cancellation fixtures) plus a
measured instruction reduction, never byte identity. Measurements and the
completed first round (checkpoint inlining, direct list element reads, the
task pointer read once per function, cleanup-frame elision, borrowed iteration
over parameters and immutable lets) are in `benchmarks/results/` and Git
history.

Working rules are in [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) and
[`COMPILER_SPEED_ROADMAP.md`](COMPILER_SPEED_ROADMAP.md) ("Reading profiles").

## The stage-2 rule

`bin/blorp` is linked by the pinned bootstrap compiler
(`blorp/build/bootstrap.env`), not by the compiler in the worktree, so a change
to the backend or to the native runtime does not change the code `bin/blorp`
itself runs. Every item below is measured on a stage-2 compiler
(`benchmarks/build_stage2_compiler`, or `benchmarks/self_compile_measure
--stage2`) against a stage-2 compiler built the same way from the base commit,
at -O2 with three samples on both the self-compile and the small program. The
candidate must lower self-compile instructions by the item's floor and must not
raise the small program's by more than 0.5%. Report `output_bytes`, the
instruction rows and the item's pattern counts. The full rule, the harness
flags and the sampling recipe are in
[`benchmarks/README.md`](../benchmarks/README.md#the-stage-2-rule) and
"Sampling A Pass" there; the pattern counts below are cheap oracles obtained by
grepping the generated C of `blorp/src/main.brp`
(`bin/blorp compile --std-dir standard_library/src --no-format
--no-embed-runtime -o out.c`). After a codegen round the bootstrap is
re-pinned so `bin/blorp` itself gets the gains.

## The per-node patterns

A small program shows each pattern; compile it and read the C:

```blorp
record Node { name: String, children: List[Node], depth: Int }

union Shape:
	Leaf(String)
	Branch(List[Shape], Int)
	Empty

pure func count_leaves(shape: Shape) -> Int:
	match shape:
		Leaf(name): 1
		Branch(items, _):
			var total: Int = 0
			for item in items:
				total += count_leaves(item)
			total
		Empty: 0

pure func rename(shape: Shape, prefix: String) -> Shape:
	match shape:
		Leaf(name): Leaf(prefix + name)
		Branch(items, depth):
			var renamed: List[Shape] = []
			for item in items:
				renamed = renamed.append(rename(item, prefix))
			Branch(renamed, depth)
		Empty: shape
```

**Pattern A: a loop that takes ownership of a borrowed list.** A loop over a
list the loop cannot free should iterate the borrowed pointer with no retain,
no duplicate slot, no cleanup frame and no release. Loops over parameters and
immutable lets already do. The ownership decision is Perceus's
(`insert_drops_for_loop_expr` and `rewrite_loop_iterable` in
`stage_09_core/perceus.brp`, with `iterable_release_policy` set by
`stage_08_core_lower/lower.brp`); the backend's `NoReleasePolicy` path already
emits no frame. Loops over match bindings of a borrowed scrutinee (`items` in
`count_leaves`) and over field chains still take ownership. Measured flat
(within noise) when borrowed on their own, because loops are 6% of
duplicate-slot sites and 12% of frames; they ride with a future Perceus change
rather than land alone. Soundness conditions for any further borrowing: the
root is a parameter or immutable binding, the loop body neither reassigns nor
consumes it (including inside lambdas, `match` arms and nested loops), and
`for item in items: items = items.append(x)` keeps iterating the original
allocation (`MEMORY_MODEL.md`).

**Pattern B: the value escapes a borrow.** A value read once as a bare value or
returned is retained at the read and released at scope end. About 40,000 of
51,882 inserted dups on the self-compile duplicate a `let` or match binding
that is read once; only about 500 to 700 of the let-bound ones have a matching
drop in scope, so the rest are required retains for borrowed values that
escape (a match binding of a borrowed scrutinee returned to the caller). A
last-use move did not change instruction counts: `RecordConstructExpr` and
`UnionConstructExpr` do not exist before Perceus, and the shape almost never
occurs. Reducing these retains needs an ownership design change (move fields
out of a unique scrutinee, or return borrowed results), not a Perceus tweak
([`OWNERSHIP_MODEL.md`](OWNERSHIP_MODEL.md) defines consumed and borrowed
positions).

**Pattern C: a record update whose source can never be unique.** A borrowed
parameter is retained before the update, so every `blorp_is_unique` test on the
copy path is dead, and the reuse call tests a third time. Emitting only the
copy path measured flat (+0.08% instructions): the test is a relaxed atomic
load and a compare, and removing about 2,000 static sites did not move the
count.

## Open work

None of these has a committed design; each starts with the measurement named.

- **Cleanup frames from calls.** After frame elision, the remaining frames come
  from `BuiltinCall` names that do not map to one C symbol and from user
  functions containing loops. Frames cost stack (the protected local is pinned
  to memory), not guard branches. Floor: frames down and instructions down on
  both programs; a cancellation fixture per elided shape that cancels inside a
  function binding managed values before and after the interval. Per-value
  `may_cancel` is already region-sensitive; narrowing closure and trait-call
  boundaries cannot help (13 of 4,713 closure calls on the self-compile have a
  provable single target), and foreign calls must stay conservative.
- **Out-of-line runtime calls.** The checkpoint and the allocator were worth
  more than any emitted pattern because they were an out-of-line call per loop
  iteration or per allocation. Look for the next such call before the next
  codegen change; candidates are `blorp_list_append`'s copy path,
  `blorp_string_concat` and `blorp_release_slow_finish`'s destructor dispatch.
  Sample a stage-2 compiler on the frozen input and attribute by runtime symbol
  first.
- **Escaping borrows (Pattern B).** The largest remaining reference-counting
  category; needs a design review with the ownership model before any code.
- **Non-atomic reference counts while single-threaded.** The measured ceiling
  was -2.3% of instructions, under the 3% bar for the dynamic design (a
  process-wide flag set before the first worker thread can touch a managed
  object) and a data-race risk that only thread sanitizer on the concurrency
  suites would catch. Re-measure the ceiling on the current runtime before
  designing anything.
- **Borrowed iteration over match bindings, field chains and `var` sources.**
  See Pattern A; take it only together with a Perceus change that has its own
  win. Each cut needs its own protecting tests as ordered ownership-event
  signatures in `test_core_perceus.brp` plus runtime memory tests under
  `--leak-check`: a loop over a parameter, an immutable let, a field of a
  parameter and a string field; a body that reassigns the iterated variable
  (must stay owned and see the original elements once); a body that passes it
  to a consuming call; a nested lambda capturing it; an early return; a
  `break`.

## Gates per change

The owning suites, then `scripts/test compiler-core-sanitize leak`, then
`scripts/compiler-check --changed --base main`; the full default
`scripts/test` once before merge, because every item changes every function's
C. A change that removes releases turns a wrong classification into a leak or a
use-after-free that only the leak checker and the sanitizer see, so run them
after each cut. A change that measures flat is dropped, not merged; a negative
result is still a reportable result. Do not change the order or placement of
`DupExpr`/`DropExpr` unless the item says so, and never parallelize Perceus or
the late Core passes.
