# Value Tuples and Owned State Hand-off

Status (2026-10-02): plan of record for `main`. Increment 1 has a validated,
unmerged implementation on `core/local-tuples-never-allocate`; increments 2-5
and 7 remain design. Section 9.1 records what that pilot actually proves.
Nothing in this document should be read as a claim that tuple flattening has
landed on `main`.

Unless a section names a newer matched comparison, "today" and all
self-compile percentages below refer to the historical design baseline,
not the current checkout. Section 9.1 separates the pilot's two
measurement revisions.

The discovery redesign ([`DISCOVERY_REDESIGN.md`](DISCOVERY_REDESIGN.md),
its sections 3.15, 3.16 and 7) threads a parse state through every parse
function and returns `(ParseState, node)`; the minting functions return
`(IdMint, node)`. The historical M0 prototype measured the tree parse of
the self-compile's bodies at 6.80 G instructions and 11.4 M allocations,
against 0.94 G and about 6,600 for the then-current parser. Roughly 80% of
those M0 allocations were tuples and record copies, not tree nodes. These
are frozen-prototype measurements, not a current-main comparison. The flip
ceiling is +1% instructions, +5% peak RSS and +1% wall time on the
self-compile, to be rechecked against a matched current baseline.

This document designs the compiler work that removes that cost for every
program, not only the parser. It is the design asked for by "make small tuples
and owned state flow through calls without copies or needless allocation, as
a principled design, not a patch". It does not tune the redesign's code.

Section numbers of the discovery redesign always carry the word "redesign"
("redesign section 7", "the redesign's section 3.16"); a plain "section N"
means this document.

Companions: [`OWNERSHIP_MODEL.md`](OWNERSHIP_MODEL.md) (the ABI this changes),
[`STRUCT_PAYLOAD_ROADMAP.md`](STRUCT_PAYLOAD_ROADMAP.md) (tuple storage, its
step S5), [`MEMORY_MODEL.md`](MEMORY_MODEL.md), and the open copy issues in
[`issues/`](issues/).

## Contents

0. [Decisions in brief](#0-decisions-in-brief)
1. [Open questions and decisions](#1-open-questions-and-decisions)
2. [What the measurements say](#2-what-the-measurements-say)
3. [Tuples as values](#3-tuples-as-values)
4. [Owned state through calls](#4-owned-state-through-calls)
5. [The remaining copy shapes and a place-based ownership model](#5-the-remaining-copy-shapes-and-a-place-based-ownership-model)
6. [Allocation lifecycle cost](#6-allocation-lifecycle-cost)
7. [Soundness](#7-soundness)
8. [Test plan](#8-test-plan)
9. [Increments](#9-increments)
- [Appendix A. Probe programs and commands](#appendix-a-probe-programs-and-commands)
- [Appendix B. Self-compile tuple census](#appendix-b-self-compile-tuple-census)

## 0. Decisions in brief

1. **Target: a tuple is not an object while it is a local, parameter or result.**
   A tuple type at the top level of a binding, parameter or function result is
   a group of independent values: locals and parameters are flattened into one
   variable per element, and a function that returns a tuple returns a C
   struct by value. A tuple type nested inside another type (a `List`
   element, a record field, an `Option` payload, a closure signature) is a
   *boxed tuple*, the `blorp_Tuple` of today. A value that comes out of a box
   keeps its box until it is taken apart, so a stored tuple is never rebuilt
   (section 3.1). This is GHC's unboxed tuples, with the boxing decided by
   the compiler instead of the programmer. The unmerged increment 1 pilot
   reaches match subjects and immutable locals built from a tuple and only
   taken apart. A `var` tuple, a local used whole, and a local built in arms
   remain boxed until later increments (section 9.1).
2. **Ownership belongs to elements.** No unboxed tuple has a reference count.
   Each element is owned, borrowed or moved on its own, by the existing rules.
   Destructuring a call result binds owned values; it does not alias a tuple.
3. **Consuming clones extend to multi-value results.** Today a function gets
   a consuming clone only for a record parameter of the same type as its
   result. After flattening, a function whose multi-value result has an
   element of a parameter's record type (`(ParseState, Expression)`,
   `(Spellings, SpellingId)`) is cloneable for that parameter. The clone owns
   it by construction. Inferred per-parameter ownership (Lean 4's model) is
   not adopted now (decided 2026-10-02); it is kept as a deferred
   alternative with a criterion for revisiting it (section 4.3).
4. **Releases at last use.** Every owned variable is released, or moved into
   its last consumer, at its last use on each path, never at the end of its
   scope; reassigning a `var` ends its old value. This is Koka's
   garbage-free Perceus. Most of the open copy issues are a second reference
   kept alive past its last use.
5. **Fields are places.** A field path of an owned record (`b.nodes`,
   `fields.mint.counts`) can be moved out and written back, as Rust's MIR
   moves out of and re-initializes places. Because a Blorp record may be
   shared, the move is the existing runtime-checked field take: a unique
   record gives up the slot (left null), a shared one keeps it and the value
   is retained. Every borrowed alias and projection counts as a use of the
   place it reads from. This replaces the per-shape take rules in
   `reuse.brp`.
6. **Simple reads may run before moves, within one expression.** A *simple
   read* is a field path or a total, constant-time builtin applied to one
   (`length`, `is_empty`) with an unmanaged result (a managed result would
   hold a reference to what the consumer updates). Within one call's
   arguments, one result's elements or one record update's replacements, a
   simple read of a place may be evaluated before a sibling that moves the
   place. The reordering is a Core rewrite, `simple_reads_first`, that binds
   each such read to a temporary ahead of its sibling; it runs after `dce`
   and before `consume_specialize` and `record_update_ownership`, so both see
   the consumer as the last use. Nothing else is reordered; in particular no
   read is hoisted above an earlier statement. That second tier is deferred
   (section 5.3).
7. **Out of scope here:** the allocator (mimalloc is a separate decision),
   non-atomic reference counts for thread-local objects, inline tuple storage
   in records, unions and lists (S5), an unboxed `Option` of a tuple, and
   `List.enumerate` materializing tuples. Sections 6 and 9 place them.

**Historical projection, not an achieved result.** With increments 1 to 4,
and increment 5 if M0 re-measured after increment 4 still needs it
(section 9), the M0 tree parse's plumbing
falls from 9.06 M allocations to about 2.3 M (1.5 M if the struct boxes inside
tuples, part of M0's unattributed 1.46 M, go with the tuples). The removals
are worth 3.5 to 4.6 G instructions at the measured 510 to 600 instructions
per allocation (section 9), so the tree stage moves from +1.45% to between
+0.33% and +0.59% of the 405 G self-compile, about +0.44% at the central
estimate, before the adapter's saving. The 405 G denominator belongs to the
older baseline used for that projection; the increment 1 pilot's later
matched baseline retired about 204.6 G instructions (section 9.1). Do not
combine the old percentage estimate with the newer baseline. Each increment
must replace its part with a matched measurement.

## 1. Open questions and decisions

Keith answered all seven questions on 2026-10-02; each carries its decision
below. The questions are stated on the premises the two reviews corrected:
the interning copy needs the last-use analysis (increment 4), not only owned
parameters (section 4.5); "a returned parameter is owned" would have been a
new rule, not today's (section 4.3); and reordering is limited to simple
reads within one expression (decision 6). Each question also carries the
recommendation it was put with, which after review adopted the reviewer's
narrower answers to questions 2, 5 and 6.

1. **One inferred ownership contract per function, in place of consuming
   clones?** Clones own exactly one parameter, double hot functions, and only
   exist for a function returning the record type it takes. Inference owns any
   number of parameters with one copy of each function. It adds two rules to
   today's inference: the source of a record update is an owning use (what
   clones existed for), and a parameter returned, alone or as an element of a
   tuple result, is owned (today a returned parameter is borrowed and retained
   at the return, as in Lean 4). The costs: an atomic increment and decrement
   when a caller passes a value still live after the call, where the callee
   copies under either scheme; and a release on each path of the callee that
   does not return the parameter, where today's borrowed parameter costs
   nothing on that path and one retain on the returning one. Neither scheme
   hands over a `var` reassigned from the result (`next = f(x); x = next`);
   that needs increment 4 under both.
   *Recommendation:* inferred contracts, accepted on the stage-2 instruction
   count measured for increments 3 and 4 together, with the returned-parameter
   rule measured on its own in increment 3 and dropped if it does not pay.
   **Decided 2026-10-02: not now.** Keith: "Unless this makes a large
   difference on self-compile time, this seems too complex to add right
   now." Increment 3 instead extends consuming clones to multi-value results
   (section 4.2), which covers the flip's path because the tree parser and
   the lexer each thread one record. Inference is kept as a deferred
   alternative (section 4.3), to be revisited only on a measured large
   self-compile difference.
2. **Do the ownership rework now, in `stage_09_core`, rather than in the Core
   rewrite?** Earlier guidance deferred ownership fixes to the rewrite; the
   discovery flip needs them first (question 7). Each piece is a separate pass
   or table the rewrite can keep.
   *Recommendation:* proceed for increments 1 to 4; re-measure M0 after
   increment 4 before committing to increment 5.
   **Decided 2026-10-02:** yes, now, in `stage_09_core` ("now. at least the
   tests will presumably be useful later on").
3. **May the compiler run a simple read earlier than it is written?** A
   simple read is a field path, or `length` or `is_empty` of one, with an
   unmanaged result. It may run before a sibling argument, tuple element or
   record-update replacement that moves what it reads; and it may move above
   an earlier statement only when it runs on every path from there, depends on
   nothing defined or assigned in between, and is not inside a branch, loop,
   lambda or `and`/`or` right operand. No user function call is ever moved, so
   `debug:` output and non-termination are never reordered.
   *Recommendation:* yes, in exactly this form.
   **Decided 2026-10-02: the first tier only.** Simple reads are evaluated
   first within one call's arguments, one multi-value's elements, or one
   record update's replacements. The second tier, hoisting a simple read above
   an earlier statement, is deferred until a census of real sites shows it is
   needed: its only evidence today is one issue
   (`read-after-builder-handoff-copies`); it cannot cover the common case,
   `state.current_span()`, which is a call; and the source fix, reading before
   handing off, is natural code rather than a contortion. Its design stays in
   section 5.3, labelled as deferred.
4. **Keep stored tuples boxed in this work?** Record fields, union payloads,
   `Option` of a tuple and list elements stay `blorp_Tuple` as today; inline
   storage is measured separately afterwards (increment 7).
   *Recommendation:* yes, keep them boxed; measure increment 7 afterwards.
   **Decided 2026-10-02:** keep stored tuples boxed.
5. **Non-atomic reference counts for objects one thread owns** (Lean 4's
   scheme): design it now?
   *Recommendation:* defer until after the allocator decision.
   **Decided 2026-10-02:** deferred.
6. **The parked branch `core/tuple-return-handoff`:** close it?
   *Recommendation:* harvest its tests into the new model's fixtures, close
   it, and keep a tag until increment 5 lands.
   **Decided 2026-10-02:** harvest the tests, close the branch, keep a tag.
7. **Should the discovery flip (M6) wait on this work?** The redesign's
   decision Q6 (its section 10) sets the ceiling "not counting on the tuple
   hand-off", and its sections 7.4 and 8 say nothing waits on it. M0 measured
   the tree stage at +1.45% on today's compiler against the +1.0% ceiling. If
   M6 does not wait, the flip likely cannot meet the ceiling, and the
   redesign's own fallbacks (a slimmer state, fewer return levels, fewer
   wrapper records) change the parser's design to fit the compiler. If M6
   waits, the flip is gated on a Core project: increments 1 to 4, and 5 if
   the re-measured M0 still needs it.
   *Recommendation:* M6 waits on increments 1 to 4, with increment 5
   conditional on re-measuring M0 after increment 4; M1 to M5 proceed in
   parallel and do not wait.
   **Decided 2026-10-02:** M6 waits, as recommended; the ceilings are
   unchanged. The redesign records it under its decision Q6 (redesign
   sections 0, 7.4, 8 and 10).

Related, not a question: whether increment 4 should rest on full SSA in Core
was assessed at Keith's request (section 5.6); the recommendation is
analysis-only versions, with no change to section 9.

## 2. What the measurements say

### 2.1 The M0 prototype

From `benchmarks/results/discovery_redesign_m0_2026-10-02.md` on branch
`compiler-new/m0-tree-prototype`:

| | Allocations | Instructions |
| --- | ---: | ---: |
| Today's parse of the bodies | 6,623 | 0.94 G |
| Tree parse of the bodies | 11.38 M | 6.80 G |
| of which retained tree | 2.32 M | |
| of which plumbing | 9.06 M | |
| of plumbing: tuples | about 3.3 M | |
| of plumbing: record and box copies | about 4.3 M | |
| of plumbing: not attributed (list growth, `Option` boxes, temporaries) | about 1.46 M | |
| The same, with the parked tuple hand-off | 9.88 M | 6.00 G |

Each node mint costs five allocations beyond the node: the `(IdMint, node)`
and `(ParseState, node)` tuples, and copies of `SyntaxCounts`, `MintState`
and `ParseFields`. One of these is the prototype's, not the design's: M0
declared `SyntaxCounts` a `record` (`m0_tree/syntax.brp`), while the
redesign makes it a `struct` inside the `MintState` record (redesign section
3.4), which is copied by value and never allocated. M0's own "struct mint"
variant measured that difference: −1.16 M allocations, one per mint. So about
1.16 M of the plumbing goes by following the redesign, with no compiler
work. A `NameUse` or `Binder` mint costs seven. A builder
returned inside a tuple and destructured cost 6.45 G instead of 3.29 G with
identical allocation counts, because whole lists were copied (memmove was 70%
of samples).

### 2.2 Probes on this branch's base

`bin/blorp` built by `make` at `9172b35e0` (`FRESH`), Apple clang 21, `-O2
-fwrapv`, Apple Silicon. Programs and commands in appendix A. Instructions
are per call, minus the `empty` loop, median of 3 (spread under 0.3%);
allocations are exact (`BLORP_MEMORY_STATS=1`, diagnostic build). Every loop
is written the way the parser writes it: `(next, x) = f(v, ...)` then `v =
next` on a `var`.

| Shape | Allocations per call | Instructions per call | Control (same work, no tuple) |
| --- | ---: | ---: | --- |
| `(Int, Int)` small enough for `tuple_sroa`'s call expansion | 0 | about 0 | |
| `(Int, Int)` from a body `tuple_sroa` cannot summarize | 1 | 574 | 0 / about 0 |
| `(Cell, Int)`, record updated, destructured | 2 | 1,103 | `cell = bumped(cell)`: 0 / 5 |
| Redesign section 3.16 mint: `(ParseState, Node)` over `(Mint, Node)`, node kept | 6 | 3,169 | same counter and node, no tuple: 2 / 1,013 |
| Recursive descent, 19 mints per call | 125 | 63,679 (3,350 per mint) | |
| `(Builder, Int)` with a growing list, 100,000 rows | 3 | 77,931 | `builder = builder.pushed_only(i)`: 0 / 39 |
| `(Builder, Cell)`, two owned records | 4 | 78,416 | one record holding both: 1 / 76,880 |

The builder shapes are quadratic: from 10,000 to 30,000 rows their
instructions grow 7.5 times. `pushed(builder, value) -> (Builder, Int)`
borrows the builder (a record update of a parameter is not a consuming use
today), retains `rows`, and the append copies a shared list on every call.

Controls that are not flat either, with no tuple involved:

| Shape (no tuple) | Allocations at 1,000 / 10,000 calls |
| --- | --- |
| `{ f | mint = { f.mint | counts = { f.mint.counts | expressions = ... } } }` (three levels) | 1 per call |
| the same update written through two local bindings | 2 per call |
| `{ p | builder = { p.builder | rows = p.builder.rows.append(v) } }` (a list two levels down) | 1,001 / 10,001 (quadratic) |
| `{ p | cell = { p.cell | count = p.cell.count + 1 } }` (a scalar two levels down) | 1 / 1 |
| an immutable alias read once, then the owner updated (`second = b; t += second.tag; b = b.grown(i)`) | 40,001 at 20,000 (quadratic) |
| the same read taken from `b` itself | 15 |
| `next = interned_alone(spellings, i); spellings = next` (section 4.5) | 2,251 / 22,501 |
| `spellings = interned_alone(spellings, i)` | 19 / 25 |

The alias pair shows the release placement directly: the alias is dead after
its read, but its reference is released at the end of the loop body, so the
update sees a shared builder and copies it and its list. The last pair shows
the `var` side: a `var` passed to a call and then reassigned from a temporary
is not handed over, while the one shape `x = f(x)` is.

### 2.3 Tuples in the historical self-compile baseline

A self-compile (`bin/blorp compile blorp/src/main.brp`) linked against a
runtime that counts `blorp_tuple_new` allocates **3,446,785 tuples** (2.83 M
pairs, 0.61 M triples, 3 quadruples); the counting binary emits byte-identical
C. Attributing each allocation to its calling function in a stage-2 compiler
built at `-O0` (appendix B) covers the 3,425,121 tuples made at sites with at
least 500 allocations each; the other 21,664 come from smaller sites.

| Where the tuple goes | Tuples | Share | After this design |
| --- | ---: | ---: | --- |
| A `match (a, b):` subject `tuple_sroa` leaves on the heap (or-patterns, literal patterns, three-element subjects) | 1,054,891 | 31% | gone |
| A local tuple built by a `match` or `if` arm and destructured | 451,066 | 13% | gone |
| Returned and destructured | 280,136 | 8% | gone |
| Returned inside an `Option` | 214,133 | 6% | boxed (section 3.7) |
| Stored in a list: association lists `List[(K, V)]` and `List.enumerate` | 1,052,834 | 31% | boxed (S5, section 9) |
| Not classified | 372,061 | 11% | |
| A box rebuilt from another box's elements | 0 | | must stay 0 (section 3.1, counted) |

So the original design projected removing about 1.79 M of 3.45 M tuple
allocations from that compiler: about 1.0 G instructions at 574 per tuple
(section 2.4), about 0.25% of that self-compile. Increment 1 has since
measured a narrower result (section 9.1); the M0 removal remains a
projection. A prior constructor-match-subject change removed 6.3 M
allocations and 1.23% of instructions. Its completed-work report was pruned
from maintained results; read it in Git history with
`git show b04950053:benchmarks/results/tuple_match_subject_sroa_2026-09-24.md`.

Historical self-compile percentages in this document use the 405 G stage-2
`-O2` self-compile in redesign section 7. The counting run above used
`bin/blorp` itself, whose compiler C is built at `-O0`, and retired 397.7 G;
it is a count of tuples, not a cost baseline.

### 2.4 What one allocation costs

| Measured on this host, `-O2` | Instructions | Cycles |
| --- | ---: | ---: |
| libc `malloc(40)` then `free` | 504 | 71 |
| atomic increment and decrement of a reference count | 7 | 9 |
| one heap `(Int, Int)` tuple, built, read and released | 574 | 91 |

In retired instructions, about 88% of an allocation's lifecycle is the system
allocator; in cycles about 78%. The generated part (variadic
`blorp_tuple_new`, header initialization, release-mask setup, the atomic
decrement, the destructor lookup by id and its loop) is about 70 instructions
and 20 cycles. This is why the mimalloc pilot cut 37% of the self-compile's
instructions, and why OCaml, whose minor-heap allocation is a pointer bump of
a few instructions, can afford heap tuples where Blorp cannot. The lever in
this document is not making allocation cheaper; it is not allocating, not
copying and not counting references. Over the whole M0 parse an allocation
averaged 600 instructions (510 in M0's isolated probe), the range used for
estimates below.

### 2.5 Why the parked hand-off bought 12%

Branch `core/tuple-return-handoff` (parked) kept the heap tuple and patched
the ownership around it: a clone for a function returning a record in a
tuple, a retain cancelled against the release at a reassignment, a tuple's
release moved after its last read, a field moved through a call whose tuple
result refills it. Each is a correct rule for one shape, together +4,367
lines. The tuple still allocated, destructured items were still aliases of
it, and a clone still owned one parameter. The measurement (−1.5 M of 11.4 M
allocations) is what per-shape rules can reach.

## 3. Tuples as values

### 3.1 The rule

Blorp tuples have two to four elements, compare and hash element by element,
and have no identity in the language: `memory.same_object` answers `False`
for stack values and `is_unique` answers `True`
([`GUIDE.md`](GUIDE.md#tuples), `standard_library/src/memory.brp`). So the
language never needs a tuple to exist as an object. The compiler needs one
only when it stores a tuple in a slot whose layout it does not own.

The rule, by type position after monomorphization:

- **Top level: a group of values.** A tuple type that is the whole type of a
  local binding, a parameter or a function result is flattened. A local `t:
  (A, B)` becomes two locals; a parameter `p: (A, B)` becomes two parameters;
  a result `-> (A, B)` becomes a *multi-value result*, returned as a C struct
  by value.
- **Nested: a boxed tuple.** A tuple type that appears inside another type
  (`List[(K, V)]`, `Option[(A, B)]`, a record field, a union payload, a
  `Dict` key or value, a function type's parameter or result, a channel's
  element) is a boxed tuple: today's `blorp_Tuple`, with its release mask.

The two meet at **sinks** and **sources**. A sink is a position whose expected
type is nested: `xs.append((a, b))`, `Some((a, b))`, `{ r | pair = (a, b) }`.
There the elements are boxed. A source is a read of a nested tuple: `xs[i]`,
a record field, a payload binding, a closure parameter.

**A box that exists is never rebuilt.** Flattening a value that came from a
box and boxing it again at a sink would turn today's retain into an
allocation. Three rules prevent it:

- **Sources keep their box.** A binding whose value is a source (`p = xs[i]`,
  `for p in pairs`, `Some(p) => ...`) stays a single boxed variable of type
  `BoxedTupleType`. Element reads are projections of the box, which borrow
  from it; a whole use at a sink passes the box itself (a retain, as today).
- **A parameter used whole at a sink keeps its box.** Flattening a parameter
  is decided from the callee's body: a parameter that the body (directly or
  through bindings) stores, captures or passes whole to a sink stays a boxed
  parameter, and its callers pass a box (an existing one by retain, or a new
  one where today's caller would also have built one). This covers a generic
  `push[T](xs: List[T], x: T)` instantiated at `T = (A, B)`. Passing a
  parameter whole to another function's boxed parameter is also a sink, so
  the decision is a least fixpoint over the call graph: every tuple parameter
  starts flattened, a parameter becomes boxed when the body uses it whole at a
  sink or passes it whole to a boxed parameter, and this repeats until nothing
  changes. Marking only ever turns flattened into boxed, so it converges, and
  recursion needs no special case.
- **A result that is always an existing box stays boxed.** A function whose
  every result path returns a source unchanged (`first(pairs) -> (A, B):
  pairs[0]`) keeps a boxed result.

**Known residual: mixed results.** A function that returns a built tuple on
some paths and an existing box unchanged on others returns a multi-value. On
the box-sourced path it returns the box's elements, and a caller that stores
the result builds a new box, where today the callee returns the existing box
by retain: one allocation instead of a retain, on that path only. The
flattening pass counts it at the callee, where it is visible: every result
path that returns a source's elements in a function with a multi-value result
is a *re-boxing path*, and the pass reports the functions that have one and
the call sites that box their result. A fixture pins the allocation count of
one such function. If the census shows the residual matters, such a function
can keep a boxed result when every one of its call sites stores the result.

Lambda bodies keep the closure ABI: their tuple parameters and results are
boxed, as the closure signature is a nested position. The flattening pass
counts every box it builds from the projections of another box, and every
re-boxing path above; the census of section 2.3 reports both counts, and the
fixtures of section 8 require the first to be 0 for the shapes above.

This is GHC's split between unboxed tuples `(# a, b #)`, which cannot be bound
to a polymorphic variable or stored, and boxed tuples, with the difference
that the programmer writes one tuple type and the compiler picks the form by
position. GHC reaches unboxed returns through its constructed-product-result
analysis and a worker/wrapper split; Blorp has no laziness or polymorphic
code after monomorphization, so the rule can be total instead of an analysis.

### 3.2 Which tuples qualify

All of them. The alternative the brief raises, qualifying by monomorphized
layout (only small, only unmanaged elements), would keep a heap form for
locals and returns whose elements are managed, which are exactly the parser's
`(ParseState, Expression)` and the compiler's `(Table, Id)`. Size is not a
reason either: a tuple has at most four elements and a multi-value result is
at most four members, each a scalar, a pointer or a struct. Layout decides
only how a *stored* tuple is represented (boxed today, inline later), never
whether a local or returned tuple is an object.

**Tuples are not made anonymous `struct`s.** A Blorp `struct` is unmanaged by
definition (every field scalar, enum or struct; no reference counting;
`test_struct_value_no_retain.brp`). A tuple holding a record is managed.
Making tuples structs would either restrict them to unmanaged elements, or
make structs managed and change what a struct promises. The multi-value
result's C struct reuses the emitter's struct machinery (a typedef, a compound
literal) as transport only: it is never a Blorp value, never a Perceus
variable, and never stored.

**Relation to S5.** S5 in the struct payload roadmap is "tuple elements typed
by monomorphized layout" in storage. This design removes the non-storage
tuples S5 never addressed (section 2.3), and leaves S5 exactly the stored
tuples: inline tuple fields in records and typed union payloads, and inline
`List[(A, B)]` storage, measured on their own after this work (section 9).

### 3.3 Core representation

`ir.brp` gains one type variant and one expression form:

```blorp
union CoreType:
	...
	-- Before tuple flattening: a tuple value. After it: a multi-value, legal
	-- only in a multi-value context (below).
	TupleType(List[CoreType])
	-- A tuple stored in a slot whose layout the compiler does not own: the
	-- runtime's `blorp_Tuple`. Every tuple type nested in another type, and
	-- every binding of a source.
	BoxedTupleType(List[CoreType])


union CoreExpr:
	...
	-- Binds each element of a multi-value: `binders` in element order, each
	-- an owned local. The value is a multi-value context.
	UnpackLetExpr(List[CoreVar], CoreExpr, CoreExpr, CoreType, CoreSourceLoc)
```

**Multi-value contexts**, defined recursively. After flattening, an
expression of `TupleType` may appear only in a multi-value context, which is:

- the body of a function whose result type is a `TupleType`;
- the value of an `UnpackLetExpr`;
- within a multi-value context, the part of any form whose value is that
  part's value: the body of a `LetExpr`, `BorrowLetExpr` or `UnpackLetExpr`;
  the last part of a `SeqExpr`; both arms of an `IfExpr`; every arm body of a
  `match`; the body of a `TailrecLoopExpr` or `TailrecListSpreadLoopExpr`; the
  body of a `ResourceScopeExpr`; after Perceus, the body of a `DupExpr` or
  `DropExpr`. A Core form added later whose value is its body's value is a
  multi-value context by the same rule, and the ingress check lists the forms
  exhaustively so a new one fails to compile until it is classified.

An expression of `TupleType` in a multi-value context is a `TupleExpr`, a call
whose result is a `TupleType`, a tail-recursion jump (`TailrecRecurExpr`,
`TailrecListSpreadRecurExpr`, which produces no value), or one of the forms
above. `tailrec` runs before flattening, so a self-tail-recursive function
returning `(A, B)` reaches flattening as a loop: the loop's body is a
multi-value context, and the loop's rebound parameters flatten like any
parameters. Anything else of `TupleType` is an error.

Existing forms keep their meaning with a narrower scope:

| Form | Before flattening | After flattening |
| --- | --- | --- |
| `TupleExpr(items)` | any tuple value | a multi-value, in a multi-value context only |
| `TupleConstructExpr(construct)` with `BoxedTupleType` | (made by `specialize`) | a boxed tuple at a sink; consumes its elements |
| `TupleFieldExpr(value, i)` | any tuple read | a projection of a boxed tuple only: an alias of the box |

This follows the `Result` precedent: `NamedType("Result")` becomes
`StackResultType` or `BoxedResultType` by layout in `runtime_projection.brp`,
and the emitter boxes a stack result at erased slots. A separate
`MultiValueType` variant was considered and rejected: `CoreType` is shared by
every Core pass, so the narrowing is a phase rule, and the phase rule is
checked where Core is admitted to ownership (below), not left to convention.

**Validation, failing loudly.** Perceus ingress already validates admitted
forms. It gains one check: after flattening, a `TupleType` appears only in a
multi-value context, and a `TupleFieldExpr` reads only a `BoxedTupleType`.
Anything else is an internal error naming the function, not a fallback to the
heap.

### 3.4 Flattening

`tuple_flatten.brp` replaces `tuple_sroa.brp` at the same pipeline position
(after `tensor_fusion`, before function-reference adaptation and
specialization). `tuple_sroa` scalar-replaces the shapes it recognizes and
leaves the rest on the heap; flattening is total over the rules below, and
its result is checked (section 3.3).

| Source shape | Core after flattening |
| --- | --- |
| `t: (A, B) = (x, y)` | `let t0 = x; let t1 = y` |
| `t: (A, B) = f(...)` | `UnpackLetExpr([t0, t1], f(...), ...)` |
| `(a, b) = e` | the same, binding `a` and `b` |
| `(a, _) = f()` | `UnpackLetExpr([a, ignored], ...)`; `ignored` is a pass temporary Perceus releases at once |
| `t[0]`, `t.0` on a flattened `t` | `t0` |
| `var t: (A, B)`; `t = e` | `var t0; var t1`; unpack `e` into temporaries, then assign both |
| whole use of a flattened `t` at a sink | `TupleConstructExpr` of `t0, t1` (a box; the only box this value ever gets) |
| whole use as an argument to a flattened parameter | `t0, t1` as two arguments |
| whole use in a multi-value context | `TupleExpr([t0, t1])` |
| parameter `p: (A, B)` not used whole at a sink | parameters `p0: A, p1: B` |
| parameter `p: (A, B)` used whole at a sink | one boxed parameter (section 3.1) |
| `f(e)` where `f` takes a flattened tuple and `e` is a call | the earlier arguments bound to temporaries, then `UnpackLetExpr` of `e`, then the call: left-to-right order is kept |
| `match (x, y):` | the elements bound once; every semantic-match accessor rooted at a tuple field is rooted at its element instead; a whole-tuple binding in a pattern is the element group |
| `match f():` on a tuple result | `UnpackLetExpr`, then the match above |
| a source (`xs[i]`, a field, a payload, a lambda parameter) | one boxed binding; elements are projections `TupleFieldExpr(box, i)`, which borrow |
| a tuple element of type `Void` | not stored: the element is `void` wherever it is read |

A multi-value with no data element left (every element `Void`) is a `Void`
result, and one with a single data element returns that element directly, so
the C never declares an empty or one-member struct.

**Function references.** A function whose signature flattened can still be
used as a value. Function-reference adaptation, which already runs after this
pass and adapts named functions to the closure ABI, gains the case: the
adapter takes the closure ABI's boxed tuples, unpacks them into the flattened
parameters, calls the function, and boxes a multi-value result. This is GHC's
worker/wrapper split; the wrapper exists only where a function is referenced
as a value, and DCE removes it otherwise. The adapter is a real function: a
struct-returning function is never called through a pointer typed as
returning `void*` (that is undefined behaviour in C).

**The call-expansion behavior stays until increment 2.** Increment 1
flattens locals but does not change signatures. The existing `tuple_sroa`
pass inlines a tiny unmanaged tuple-returning function at its call (the
probe's `pair_inline`, 0 allocations). The pilot retires that pass and keeps
the behavior in `tuple_element_producers.brp`; increment 2, which makes
tuple results allocation-free, deletes the expansion.

### 3.5 C representation

A function with a multi-value result returns a generated struct:

```c
/* (Cell, Int) */
typedef struct { brp_ty1* e0; long e1; } brp_mv1;

static brp_mv1 cell_pair(brp_ty1* cell);

brp_mv1 r = cell_pair(cell);
brp_ty1* next_cell = r.e0;
long n = r.e1;
```

- **Naming and identity.** A multi-value layout table in the emitter issues
  `brp_mvN` names, keyed by the list of canonical element types (a structural
  type's identity is its structure; `TYPE_INTERNING_ROADMAP.md` will make
  that key an interned id). Ids are issued in first-use order of a
  deterministic traversal, so the C is stable, and live for one emission.
- **ABI.** Structs of up to 16 bytes (two pointers, or a pointer and an
  `Int`) return in two registers on AArch64 and x86-64 System V; three or
  four pointers return through a caller-provided slot (`x8` or a hidden
  pointer); Windows x64 returns anything over 8 bytes that way. None of these
  touch the heap, and the C compiler handles all of them.
- **No undefined behaviour.** Initializer-list evaluation order is
  unspecified in C, so elements are evaluated left to right into temporaries
  before the compound literal (the emitter's normal form already does this).
  Every member is initialized. No struct is compared, hashed or copied by
  bytes, so padding is never read. Members are plain types, never bitfields.
  `Bool` members use the same C type as a local `Bool`.
- **Struct elements are inline.** A `NameUse` struct in `(ParseState,
  NameUse)` is a member by value: the `blorp_box_struct` that a tuple element
  of struct type costs today (`TupleStructElement`) disappears.

### 3.6 Element ownership

| Event | Ownership |
| --- | --- |
| Building a multi-value | Each element transfers into the result exactly as a single returned value does: an owned local at its last use moves, a borrowed value or alias is retained. |
| `UnpackLetExpr` of a call | Each binder is a fresh owner (`Owned`). No aggregate exists, so nothing else is released. |
| `UnpackLetExpr` of a `TupleExpr` | The elements' own facts carry over: a fresh value is owned, a borrowed one stays borrowed. |
| Partial use | An unused element is bound to a pass temporary and released at once. |
| A source | One boxed binding, borrowed from its container like any projection; its element projections are `Alias(box)`, retained only if they escape. |
| Boxing at a sink | `TupleConstructExpr` consumes each element like a record construction consumes its fields. |
| Capture by a closure | A flattened local is captured element by element; a boxed tuple is one captured owner. |
| The same value twice: `(b, b)` | The second use retains; both elements share one record, and an update of either copies it. Value semantics hold. |

Perceus never sees a variable of `TupleType`. It needs two additions: an
`UnpackLetExpr` binds owned values (the same plan as a managed `let` of a
call, once per binder), and a multi-value transfers each element (the same as
one returned value). Branch balancing of an `if` whose arms are multi-values
is done per element.

### 3.7 Boundaries that keep the box

| Boundary | Why it is boxed | Later |
| --- | --- | --- |
| `List`, `Set`, `Dict` elements, keys, values | the runtime's slots are `void*` | inline `List[(A, B)]` storage (S5) |
| Record fields and typed union payloads of tuple type | kept as today to bound this change | flattened into fields (S5) |
| `Option[(A, B)]`, `Result[(A, B), E]` | the payload slot is a pointer | an unboxed option or result of a multi-value (a tagged struct, as `StackOption` is for scalars) |
| Closure, task and channel signatures; lambda bodies | the closure ABI passes `void*` | typed closure environments (S3) and adapters |
| Runtime helpers that make or take tuples (`zip`, `List.enumerate`, dictionary entries, process options) | their C signatures use `blorp_Tuple*` | `for (i, x) in xs.enumerate()` lowered without a list |
| Foreign functions | no Blorp signature declares a tuple today; if one is added it is boxed at the boundary | |
| Globals of tuple type | stored, and already emitted as static immortal tuples | |
| Whole-tuple operations implemented as runtime helpers (printing, interpolation) | they take `blorp_Tuple*` | the ones written in Blorp take flattened parameters already |

Each of these allocates exactly as it does today: a box is built where today's
code builds one, and a box that exists is passed on by retain (section 3.1).

**Identity builtins.** `same_object`, `is_unique` and `refcount` are generic
builtins whose argument is a sink. Increment 2 decides their answer for a
tuple statically, as for any stack value (`same_object` is `False`,
`is_unique` is `True`, `refcount` is 0, as `memory.brp` documents for stack
types), instead of boxing the argument to
ask the runtime; and it updates the comments in `memory.brp` and the GUIDE's
tuple section to say that tuples are values. Today `same_object(t, t)` on a
heap tuple answers `True`; after increment 2 it answers `False`, as it does
for every other stack value.

### 3.8 Example: `cell_pair`

The probe's `record_pair` shape:

```blorp
pure func cell_pair(cell: Cell) -> (Cell, Int):
	({ cell | count = cell.count + 1 }, cell.count)


-- in a loop over a `var cell`
(next_cell, n) = cell_pair(cell)
cell = next_cell
checksum += n
```

Today's C (from the probe, names shortened):

```c
static blorp_Tuple* cell_pair(Cell* cell) {           /* cell borrowed */
  Cell* tmp = ({ blorp_retain(cell); cell; });
  Cell* updated = ({                                  /* a fresh copy */
    long count = cell->f0 + 1;
    String* label = tmp->f1; blorp_retain(label);
    Cell_make(count, label);
  });
  blorp_release(tmp);
  return ({ blorp_Tuple* t = blorp_tuple_new(2, updated, (void*)(long)cell->f0);
            blorp_tuple_set_rc(t, 1UL); t; });
}

/* caller, per iteration */
blorp_Tuple* t = cell_pair(cell);
Cell* next_cell = ({ Cell* e = t->elem[0]; blorp_retain(e); e; });
long n = (long)t->elem[1];
Cell* moved = ({ blorp_retain(next_cell); next_cell; });
blorp_release(cell);
cell = moved;
checksum += n;
blorp_release(next_cell);                              /* at the end of the scope */
blorp_release(t);
```

Two allocations, five reference-count operations and a tuple destructor per
call, 1,103 instructions. The target, which needs four pieces:

```c
typedef struct { Cell* e0; long e1; } brp_mv1;

static brp_mv1 cell_pair(Cell* cell) {                /* cell owned (increment 3) */
  long count = cell->f0;                              /* simple read first (increment 3) */
  Cell* updated = Cell_update_f0(cell, count + 1);    /* in place when unique */
  return (brp_mv1){ updated, count };                 /* no box (increment 2) */
}

/* caller */
brp_mv1 r = cell_pair(cell);                          /* cell handed over (increment 4) */
cell = r.e0;
checksum += r.e1;
```

The pieces, and what each alone leaves:

- **Increment 2** removes the tuple: one allocation and the tuple's
  destructor go.
- **Increment 3** makes `cell` owned (it is the source of a record update)
  and runs the simple read `cell.count` before the update consumes `cell`.
  Without that read moved, `cell` is live after the update, and value
  semantics force the copy.
- **Increment 4** hands the caller's `var cell` over: its use in the call is
  its old value's last use, because the next event on `cell` is the
  reassignment. Without it the caller retains `cell` across the call and the
  callee's update finds it shared (section 4.5 shows this shape copying
  today with no tuple at all).

## 4. Owned state through calls

### 4.1 Today

Managed parameters are borrowed by default (`OWNERSHIP_MODEL.md`, "Source
Function Boundary"). Ownership inference makes a parameter consumed when the
body stores it (a constructor takes it over) or hands it to a consuming
parameter; a parameter that is only returned stays borrowed and is retained
at the return; and a record update of a borrowed
parameter does not count: it builds a fresh record. To update in place,
`consume_specialize.brp` makes a *consuming clone*: a copy of the function
whose origin `ConsumingClone(index, declared_as)` declares one parameter
owned. A clone is made only for a record parameter of a function returning the
same record type (`function_is_cloneable`), kept only if a benefit fixpoint
finds an in-place update behind it, and called only where the argument is at
its last use by the pass's own liveness walk. The self-compile had 160 clones
at `710a799c7`.

A parameter that is only returned is borrowed today: the callee retains it
at the return (`OWNERSHIP_MODEL.md`, "Source Function Boundary"; in the probe,
`interned_alone`'s original returns `spellings` with a retain). A parameter of
a tuple-returning function is owned only when the tuple constructor takes it
over as an operand, which inference counts as storing it
(`interned_spelling`'s `spellings`, which one arm puts in its result tuple),
and never through a clone, because a tuple-returning function is never
cloneable today. Even when it is owned, an update inside the callee is in place only if the argument arrives
with no other reference, and two things in today's compiler usually supply
one: the caller's `var` is not handed over (section 2.2's last rows), and
inside the callee an alias of the parameter that is still read later is
passed to the borrowing original of the next function (section 4.5).

### 4.2 Increment 3: consuming clones for multi-value results

**The change.** `function_is_cloneable` (`consume_specialize.brp`, line 271)
accepts a record parameter when the result type is the same record type. It
gains one case: the result is a multi-value (`TupleType` after flattening)
and one of its elements has the parameter's record type. Everything else in
the scheme stays: one owned parameter per clone (`ConsumingClone(index,
declared_as)`), the benefit fixpoint, retargeting at last use. Four
supporting changes make such a clone useful:

- **The last-use walk models multi-value results.** Today the walk treats a
  tuple's items as code it does not model (the cause the parked commit
  `89abf8ce6` fixed). After flattening, a multi-value's elements are evaluated
  in order like call arguments, and an `UnpackLetExpr`'s binders are
  `let`-bound locals the walk tracks (so `after_condition` above can be handed
  to the next clone).
- **The benefit filter sees an update in an element.** A clone whose owned
  parameter, or an alias of it, is updated inside an element of its result
  (`({ cell | ... }, n)`, `{ fields | mint = mint }` in the first element) has
  `UpdatesOwnedRecordInPlace`.
- **Record-update ownership, rule 2, follows elements.** "A clone's owned
  parameter in the clone's result" takes the owner when the update is a
  multi-value element, not only the whole result.
- **Simple reads first** (decision 6, decided as question 3), within one
  call's arguments, one multi-value's elements and one update's
  replacements, so that `state.module` in a later element does not keep
  `state` live past the update in an earlier one. It is the Core rewrite
  `simple_reads_first`, run before `consume_specialize` and
  `record_update_ownership`: otherwise `with_text_appended(state)` is not a
  last use when those passes look at it.

**Contract parity for result elements.** Today a parameter placed in a tuple
result is consumed by the original function too, because the tuple
constructor takes it over. Flattening removes the constructor, so increment 2
counts an element of a multi-value result as a constructor operand for
ownership inference: for result elements, every original keeps exactly
today's contract. No new rule is added for single results.

Increment 1 also removes constructors that are not results: the local tuples
and `match` subjects `tuple_sroa` leaves on the heap. A parameter that today
is consumed only because such a tuple takes it over (`match (p, q):` with `p`
a parameter) becomes borrowed after increment 1. That shift is expected, not
prevented: a borrowed parameter costs its callers nothing. Increment 1 lists
every function whose contract changes and measures the effect.

**"Returned means owned" for clones and originals.** A clone owns its
parameter by its `ConsumingClone` declaration, whatever the body does with
it, so a clone of `interned_spelling` owns `spellings` on both arms. In the
originals, the rule stays exactly where it is today: a parameter placed in a
tuple result is owned (by the parity rule above), and a parameter returned
alone is borrowed and retained at the return. It is not extended to single
results, so the cost the review raised (releases on paths that do not return
the parameter) does not arise.

**What it removes, by the shapes of sections 4.4 and 4.5:**

| Cost | With extended clones |
| --- | --- |
| M0: the `ParseFields` copy per mint (about 1.2 M) | removed where the state reaches `finished_expression` through immutable binders and call results, the recursive-descent chain of section 4.4 (increments 2 and 3); in `var` loops, with increment 4. The same as inference would. |
| M0: the `MintState` copies (about 1.2 M) | removed with increment 5: `fields.mint` is a field place moved out, retargeted to `minted_expression`'s clone, and written back. Single-parameter clones suffice. The same as inference would. |
| M0: the `SyntaxCounts` copies (about 1.2 M) | not compiler work: the redesign makes `SyntaxCounts` a `struct`, so there is no allocation to remove (section 2.1). |
| Interning, cause (b): the alias passed to a borrowing function | removed with increment 4, not 3. The lexer calls `interned_spelling` from a `var` loop, so until increment 4 it reaches the original, not the clone; and in the original, the walk does not know `spellings` is owned, because that ownership comes from inference, which runs after it. With increment 4 the caller reaches the clone, which owns `spellings`; with `state.module` and `state.texts.length()` read first, `state`'s call to `with_text_appended` is its last use, and the walk retargets it to that function's clone (it returns the record it takes, so it is cloneable today). |
| Interning, cause (a): the caller's `var` kept across the call | increment 4, as before. |
| `record_pair`, builder in a tuple | increment 4. The probes are `var` loops, so until then their calls reach the originals; with increment 4 they reach the clones of `cell_pair` and `pushed`, which update in place. |
| Two owned records in one call (`step(b, s, i) -> (Builder, Cell)`) | **one copies.** A clone owns one parameter; the other is borrowed and copied on each call. In the probe the builder is the one cloned (its update reaches an append), so the quadratic list copy goes, and one `Cell` copy per call remains. |

**What still needs more than one owned parameter, and whether it is on the
flip's path.** Only functions that thread two or more records and update
each. The tree parser threads one `ParseState` (the mint is inside it), the
mint functions one `IdMint`, and the lexer one `Spellings`
(`interned_spelling` is its only tuple-returning function; `source` is a
borrowed string). The M0 measurement driver threads one builder. So none is
on the flip's path as designed; `two-owned-records-in-one-call-copy-one.md`
stays open.

**Cost in code** (estimates, from the parked branch's analogous commits):
candidacy, benefit and record-update rule 2 for results inside a tuple took
about 250 changed lines there (`92a0d9ef4`: `consume_specialize.brp` 147,
`record_update.brp` 106); modelling result elements in the walk about 25
(`89abf8ce6`); `UnpackLetExpr` binders as tracked locals and the parity rule
in inference perhaps 50 to 100 more. In all about 300 to 400 lines changed in
`consume_specialize.brp`, `record_update.brp` and `ownership_contracts.brp`,
not counting tests,
against deleting `consume_specialize.brp`'s 2,078 lines and rewriting
contracts under inference. The extension also adds clones: every
tuple-returning function with a record parameter that reaches an in-place
update gets a second copy, so the emitted C grows; increment 3 measures by how
much.

**Not added:** a rule handing a `var` over in `(t, y) = f(x); x = t`. That is
increment 4's general rule (a write ends the old value). In increment 3,
consume-specialization's destination forwarding (`consume_specialize.brp`,
its header: `t = f(out); out = g(t)` rewritten to `out = f(out); out =
g(out)`) stays as it is. Increment 4 deletes it, because the place analysis
covers that shape directly (the write `out = g(t)` ends `out`'s old value, so
its use in `f(out)` is a move), and a rewrite of the body between the
analysis and its consumers would invalidate the analysis's occurrence
ordinals. If increment 4 slips, `(t, y) = f(x); x = t` can be added to
forwarding as a fallback.

### 4.3 Deferred alternative: inferred per-parameter ownership

Not adopted now (section 1, question 1). Kept so it can be revisited.

**The idea.** Lean 4 compiles a pure language with in-place updates using one
version of each function. Its borrow inference marks a parameter owned when
the body resets and reuses it, passes it to an owned parameter, or stores it
in a constructor, and borrowed otherwise; a borrowed parameter that is
returned gets an increment at the return. A caller passes an owned argument
by move at its last use and retains it otherwise; the callee's update checks
uniqueness at run time and copies only a shared value. For Blorp it would
mean one contract per function: a parameter is owned when it, or an immutable
alias of it, is the source of a record update or the receiver of a consuming
collection operation, is stored, captured or transferred, is passed to an
owned parameter, or (a new rule) is returned, alone or as a result element.
`consume_specialize.brp` and its clones would be deleted, and
`record_update.brp`'s three ownership rules would become one.

**What it would buy over extended clones:** any number of owned parameters
(the two-owned shape), no second copy of each cloned function, one liveness
notion instead of the clone walk's, and about 2,000 fewer lines. **What it
would cost:** an atomic increment and decrement when a caller's argument is
still live after the call (the callee copies under either scheme), a release
on paths that do not use an owned parameter, and a rewrite of every
function's contract at once.

**Criterion for revisiting:** a measured large difference in self-compile
time-to-C. The measurements that would show it, all on the stage-2
self-compile with `self_compile_measure --stage2`:

- after increment 3: the clone count, the emitted C bytes, and the time spent
  compiling the emitted C, against the increment's parent; a large growth
  from clones of tuple-returning functions is the cost inference would
  remove;
- after increment 4 or 5: the M0 ledger's remaining copies that need a
  second owned parameter (today none are known), and the self-compile's
  retained copies of the two-owned shape, counted with the census method of
  appendix B applied to record copies;
- if either is large, a prototype of inference on one stage (Core passes'
  own threaded tables are the likeliest beneficiaries), measured against the
  same parent.

Today's evidence shows no such difference: the increment-3 estimates under
inference listed nothing for the self-compile beyond 160 fewer clones (less
C) and extra caller retains.

### 4.4 Recursive descent

The redesign's section 3.16 shape:

```blorp
private pure func parse_if(state: ParseState, context: BodyContext) -> (ParseState, Expression):
	keyword: Span = state.current_span()
	(after_condition, condition) = state
		.advanced()
		.parse_expression(context)
	(after_then, then_block) = after_condition
		.expect_colon(ColonInIfCondition)
		.parse_block(context)
	(after_else, else_branch) = after_then.parse_else_branch(context)
	...
	after_else.finished_expression(span, If({...}))
```

Each of `parse_if`, `advanced`, `parse_expression`, `expect_colon`,
`parse_block`, `parse_else_branch` and `finished_expression` gets a consuming
clone owning `state`, because each returns its state as an element of its
result (or alone) and updates it on some path. The core of the clone of
`parse_if` after flattening (schematic; `move` marks a use Perceus does not
retain):

```text
parse_if__consume_arg0(state: owned ParseState, context: BodyContext) -> (ParseState, Expression):
  let keyword = current_span(state)                      -- borrow; ends before the move
  unpack [after_condition, condition] =
    parse_expression__consume_arg0(advanced__consume_arg0(move state), context)
  unpack [after_then, then_block] =
    parse_block__consume_arg0(
      expect_colon__consume_arg0(move after_condition, ColonInIfCondition),
      context,
    )
  unpack [after_else, else_branch] =
    parse_else_branch__consume_arg0(move after_then, context)
  ...
  finished_expression__consume_arg0(move after_else, span, If({...}))  -- tail
```

Every hand-off here is an immutable binder or a call result at its last use,
which today's Perceus already moves (the `named_local` and `chained_receiver`
rows of `consume_owned_threading_shapes.brp` are flat) and which the clone
walk retargets to the callees' clones, so increments 2 and 3 are enough for
this function. Each state is handed down by move, updated in
place, and handed back as an element of a multi-value. The parts of the
parser that keep the state in a `var` across a loop (`var state = ...; while
...: (next, statement) = state.parse_statement(); state = next`) need
increment 4. The `(IdMint, node)` level inside `finished_expression` needs a
field moved out of the state and written back (increment 5, section 5.3).

### 4.5 Worked example: one-call spelling interning

The lexer's spelling table (redesign step M2) needs the one-call interning
API, because the two-call lookup-then-add API it replaces let two diverged
tables hold one spelling twice:

```blorp
opaque type Spellings = InternedSpellings

private record InternedSpellings {
	module: ModuleId,
	texts: List[String],
	slots: List[Int]
}


pure func interned_spelling(
	spellings: Spellings,
	source: String,
	start: Int,
	end: Int,
) -> (Spellings, SpellingId):
	state: InternedSpellings = from_opaque Spellings(spellings)
	hash: Int = slice_hash(source, start, end)
	found: Int = find_slice(state.texts, state.slots, source, start, end, hash)

	if found == NO_ROW:
		row: Int = state.texts.length()
		(
			into_opaque Spellings(with_text_appended(state, source, start, end, hash)),
			spelling_id(state.module, row),
		)
	else:
		(spellings, spelling_id(state.module, found))


-- in the lexer, once per word, `spellings` a `var`
(interned, name_spelling) = interned_spelling(spellings, text, name_start, end)
spellings = interned
```

Against the two-call version, the discovery `tables` stage costs +1.7 G
instructions (+32%) and +1.06 M allocations (the coordinator's measurement).
Two costs:

1. **A tuple per word**, hit or miss: 0 to 1 allocation per word. A record
   result costs the same, and a `struct` cannot hold `Spellings`.
2. **The miss arm copies** the record and both lists: about 3 allocations per
   new spelling, plus O(table) of list copying.

**Why the miss arm copies.** A probe with the same arms over a two-list
record (appendix A, 1,000 / 10,000 calls, three of four calls a miss), and
the generated C of its `given` variant (the shape above), show it:

| Variant | Allocations |
| --- | ---: |
| `-> (Spellings, Int)`, hit arm returns the given `spellings` (`given`) | 3,251 / 32,501 |
| the same without any read of `state` in the second element | 3,251 / 32,501 |
| `-> (Spellings, Int)`, hit arm returns `into_opaque Spellings(state)` | 3,251 / 32,501 |
| `-> Spellings`, called as `next = f(spellings, i); spellings = next` | 2,251 / 22,501 |
| `-> Spellings`, called as `spellings = f(spellings, i)` | 19 / 25 |

In `given`, today's inference already makes `spellings` owned, because the
hit arm puts it in the result tuple, whose constructor takes it over; the
callee releases it on the miss arm. Two references
still meet in the miss arm:

- **(a) The caller keeps its `var`.** The call is `blorp_retain(spellings);
  interned_given(spellings, i)`, and the caller releases its own reference
  only at `spellings = next`. The table is shared for the whole call.
- **(b) The callee keeps its alias.** `state` is retained at entry (it is an
  alias of `spellings`, which the other arm still uses) and is passed to
  `appended`'s borrowing original, not to its consuming clone, because
  consume-specialization's walk does not model a tuple's elements and `state`
  is read again in the second element.

The tuple-free rows separate them. With no tuple, a call written `next =
f(spellings, i); spellings = next` still copies on every miss. There the
symptom is different: the caller does not retain, it calls `f`'s borrowing
original, because consume-specialization does not see the `var`'s use as its
last use when the `var` is reassigned from a temporary. The root is the same
as (a): a `var` is not handed over at a call whose result replaces it. The same function called as `spellings = f(spellings, i)` is flat,
because consume-specialization recognizes that one shape and the callee's
alias is retained and its source released before the call, leaving one
reference (cause b does not arise without the tuple).

**Which increment removes what:**

| Cost | Removed by | How |
| --- | --- | --- |
| The tuple per word | multi-value results (increment 2) | the result is `{InternedSpellings*, long}`, returned in two registers; `interned` is an owned binder |
| (b) the alias passed to a borrowing function, and `state.module` read after the update | consuming clones for multi-value results, with simple reads first (increment 3) | the clone of `interned_spelling` owns `spellings`; `state.module` and `state.texts.length()` are simple reads, evaluated before the first element consumes `state`, so the call to `with_text_appended` is `state`'s last use and goes to that function's existing clone; on the miss path `spellings` is released before the call, as the tuple-free variant already does, so `state` arrives with one reference from the callee's side |
| (a) the caller's `var` kept across the call | last-use releases (increment 4) | `spellings`' old value is dead after the call, because the next event on it is the reassignment; its use in the call is a move |

Increment 2 alone removes one allocation per word and leaves the miss arm
copying. Increments 2 and 3 together still copy on every miss, because of
(a). The whole cost goes only with increments 2, 3 and 4.

**Expected cost after increments 2 to 4:** a hit allocates nothing and costs
the lookup (`slice_hash`, `find_slice`) plus a struct return; a miss
allocates the spelling's text and the amortized growth of `texts` and
`slots`, with no record or list copy. The one-call version should therefore
drop the whole +1.06 M allocations and +1.7 G instructions, and land at or
slightly below the two-call version, which looks a new spelling up before
adding it. Increment 4 replaces this estimate with the `tables` stage
measurement.

The historical issue `branch-returning-given-table-copies-on-update`
(removed from the open-issue index; see Git history at `68b46c9b9`)
recorded these two causes. The hit arm's return of the given table is not
one of them: the tuple-free variant with the same arms is flat.

### 4.6 What is deleted, and what stays

- Deleted in the increment 1 pilot: the `tuple_sroa.brp` pass; its surviving
  call expansion and `if`/`match` producers move to
  `tuple_element_producers.brp`. Increment 2 deletes that module's call
  expansion and replaces the producers with a multi-value binding
  (section 3.4).
- Deleted: `reuse.brp`'s field-take rules, in increment 5.
- Deleted: consume-specialization's own last-use walk, in increment 4, which
  replaces it with the place analysis's liveness (section 5.5).
- **Stays:** `consume_specialize.brp`, `ConsumingClone(index, declared_as)`
  with one owned parameter, the benefit fixpoint, and `record_update.brp`'s
  three ownership rules (rule 2 extended to result elements). These would go
  only with the deferred alternative of section 4.3.

The parked branch is not landed. Its tests, especially
`test_nested_record_field_take_ownership.brp` and the nested-field fixture
rows, are harvested as regression tests for the new model.

## 5. The remaining copy shapes and a place-based ownership model

### 5.1 The shapes

| Issue | Shape | Cause |
| --- | --- | --- |
| `alias-move-blocked-by-condition-read` | `var out = b; if b.nodes.length() ...: out = out.f()` | `b`'s reference is released at the end of the scope, not after the condition |
| `chain-on-reassigned-builder-var-copies` | `out.f().g()` after `out` is reassigned under a branch | ownership at the join is summarized as possibly shared; the chain keeps a reference |
| `read-after-builder-handoff-copies`, `var` in an arm | `if c: b.f() else: var out = b ...` | the arm's alias keeps `b` alive |
| `read-after-builder-handoff-copies`, read after | `h = b.f(r); n = b.nodes.length(); h.f(n)` | `b` is genuinely live after the hand-off |
| `builder-captured-or-stored-copies`, closure | a closure reads `b`, is called once, and is dead | the closure is released at the end of the scope |
| `builder-captured-or-stored-copies`, record | `holder = {held = b}; holder.held.f()` | a field of an owned record cannot be moved out |
| `field-moved-into-loop-var-copies` | `var edges = family.edges; for ...: edges = edges.append(c); { family | edges = edges }` | the field take does not cross a `var` or a loop |
| `record-update-same-field-read-copies` | `{ b | nodes = b.nodes.append(row(b.nodes.length())) }` | the take empties the slot at the receiver, before a later argument reads it |
| `two-owned-records-in-one-call-copy-one` | `(b, s) = step(b, s, i)` | a clone owns one parameter |
| this document, section 2.2 | a three-level update; a list two levels down | the take rules handle one level of user call |
| this document, section 2.2 | `next = f(x); x = next` on a `var` | the `var` is not handed over unless the call's result is assigned to it directly |
| `chain_assign_in_conditional` (recorded gap) | `if c: out = out.f().g()` then `out.h()` | as the reassigned-`var` shape |

They have three causes, not twelve:

1. **References outlive their last use.** Perceus releases many let-bound
   owners at the end of their scope (section 2.2), and a `var`'s old value
   lives until its reassignment. A second reference that is dead but not yet
   released makes the next update copy.
2. **Ownership is tracked per variable.** A field of an owned record is moved
   only by pattern rules in `reuse.brp` (`take_self_consumed_record_fields`,
   `take_self_consumed_cow_fields`, and the hoisted form found by
   `find_hoisted_field_alias` and applied by `take_hoisted_field_alias`), each
   with its own window: straight-line, one level, one user call, no `var`, no
   loop.
3. **Evaluation order is taken literally.** A read of a place is evaluated
   after a sibling consumes the place, so the place must survive the consumer
   and the consumer copies.

### 5.2 Which foundation

The brief asks whether a unified place-based model is the right foundation
rather than more per-shape rules. It is, and the parked branch is the
evidence for the alternative: seven commits, each correct, for 13% of the
plumbing. The recommended model takes one idea from each of three systems,
each where it is strongest:

- **Between functions, today's consuming clones**, extended to multi-value
  results (section 4.2). Lean 4's one inferred contract per function is the
  deferred alternative (section 4.3).
- **For variables, Koka's Perceus:** every owned variable is released, or
  moved into its consumer, at its last use on each path. Koka calls this
  garbage-free: no object is kept alive past its last use, so the uniqueness
  an in-place update needs is never lost to a dead reference.
- **For fields, Rust's MIR:** a field path of an owned record is a *place*
  that can be moved out and later re-initialized, with a static state per
  place at each program point (initialized, moved, maybe moved), as Rust's
  move paths and drop elaboration track it. Blorp differs from Rust in one
  way: a record may be shared at run time, so a move out of a field is the
  existing conditional take (unique: take and leave null; shared: retain).
  Lean 4's expand-reset-reuse step does the same runtime split for the fields
  of a constructor being reused.

And one fact Blorp has that lets it go further: a simple read (a field path,
or `length` of one) is total, constant-time and has no effects, so running it
earlier than written, among the operands of one expression, cannot be
observed. Decision 6 uses that, and only that.

### 5.3 The model

**Places.** A place is a local or parameter, or a field path from one through
heap-record fields: `b`, `b.nodes`, `fields.mint.counts`. List elements and
union payloads are not places in this design.

**Derived borrows resolve to their root.** Perceus has borrowed aliases that
do not raise a reference count: `BorrowLetExpr`, `Alias(owner)` facts, match
payload bindings that borrow the scrutinee, projections of a boxed tuple.
Every such alias is resolved to the place it reads from, and each of its uses
is a use of that place. So in

```blorp
n = b.nodes
b2 = { b | nodes = b.nodes.append(1) }
n.length()
```

the read `n.length()` is a use of the place `b.nodes` after the update's
consuming use of it, so that use is not a last use, the take is demoted, and
the append copies: `n` keeps the old list, as value semantics require.
Without this rule the take would see a unique `b`, empty the slot, and grow
the list in place under `n`; and a release of `b` moved ahead of `n`'s last
use would free the list `n` reads (a use-after-free only ASan shows). Before
Perceus, where the analysis cannot yet know which bindings Perceus will
borrow, every immutable binding whose value is a variable or a field path,
every match payload binding (an alias of the scrutinee's place) and every
projection of a boxed tuple (an alias of the box's place) is treated as an
alias of its root; that is conservative (it can only demote a move). After Perceus, the release step of increment 4 reads the exact
`BorrowLetExpr` and alias facts.

**`var` reassignment is a write.** Assigning `x = e` writes the place `x`.
The old value's last use is its last read before the write; the write starts
a new value. On a loop's back edge it is the new value that is live, so in
`for ...: out = out.f()` the use of `out` in `out.f()` is the old value's last
use, and a move.

**One analysis per function.** Before consume-specialization, one pass
computes for each managed place:

- its uses, in evaluation order, each classified as a read (borrow, including
  every use of a derived borrow), a consuming use (an owning position from
  section 4.3), a whole-value use of a base (a use of `b` is a use of every
  place under it), or a write (a `var` assignment, or the re-initialization
  of a field by a record update);
- liveness: whether the place's current value is read again on some path
  after each use (backward, over Core's structured control flow; a write ends
  the value; a loop's back edge carries the value live at the loop's end);
- move state: initialized, moved or maybe moved at each point (forward; a join
  of moved and initialized is maybe moved).

**Decisions it makes**, which consume-specialization, Perceus and the reuse
pass then carry out instead of rediscovering:

1. A consuming use of a place at its last use is a **move**: no retain. For a
   variable the reference transfers. For a field path it is a conditional
   take of the slot.
2. A consuming use that is not the last use is a **copy**: a retain, and the
   consumer copies at run time if it updates.
3. An owned variable with no consuming last use is **released right after
   its last use** on each path where it is live on entry and dead after, and
   never before the last use of a borrow derived from it.
4. A field may be moved only if, on every path from the move, the field is
   re-initialized or the base record dies before any read of the field, any
   use of a borrow derived from the field or the base, or any whole-value use
   of the base; and no path leaves the window (`break`, `continue`, `?=`, a
   resource cleanup exit, a tail-recursion jump) while the base outlives it.
   Otherwise the move is demoted to a copy. Demotion costs a copy, never
   correctness.
5. **Simple reads first, within one expression.** Within one call's
   arguments, one multi-value's elements, or one record update's
   replacements, a simple read (unmanaged result) of a place that a sibling
   moves is evaluated, into a temporary, before the sibling. This is the only
   reordering planned (decided 2026-10-02, section 1, question 3).

   **Deferred design: hoisting across statements.** Not planned until a
   census of real sites shows it is needed. Kept here so the work is not
   lost: a simple read written after a statement that consumes its place
   could be hoisted above that statement only if all of these hold:
   - it runs on every path from the consumer to where it is written: no exit
     edge (`break`, `continue`, `?=`, a cleanup exit) between them, and it is
     not nested in an `if` or `match` arm, a loop body, a lambda, or the right
     operand of `and` or `or`;
   - every variable it mentions is defined before the consumer, and no `var`
     it mentions is written between them;
   - it is a field path or a total constant-time builtin over one (`length`,
     `is_empty`) with an unmanaged result, never a call of a user function.

   Nothing else is reordered. Because a moved simple read never calls a user
   function, it cannot diverge, overflow the stack or contain a `debug:`
   block, so no output and no termination behaviour changes.

**Why moves happen at the call.** `OWNERSHIP_MODEL.md` already says a
variable passed to a consuming slot "is transferred when the callee starts".
Applying that to field places too is what makes `{ b | nodes =
b.nodes.append(row(b.nodes.length())) }` flat: the `length()` read happens
while arguments are evaluated, the take happens at the call.

**Data.** The analysis produces a per-function place table: a place id is
issued for each (root binder, field path) the function mentions, keyed by the
binder's resolved value id and the `CoreFieldRef` ids of the path, never by a
spelling; each derived borrow maps to its root place id. Uses are identified
by their occurrence ordinal in one fixed traversal, as Perceus's occurrence
index already does. The table is authoritative for one function's ownership
decisions, built once, read-only after, and dropped when the function is
done; no id outlives it or is stored in Core.

**Example: the mint inside `finished_expression`.**

```blorp
pure func finished_expression(state: ParseState, span: Span, kind: ExpressionKind) -> (ParseState, Expression):
	fields: ParseFields = from_opaque ParseState(state)
	(mint, expression) = fields.mint.minted_expression(span, kind)
	(into_opaque ParseState({ fields | mint = mint }), expression)
```

The analysis sees `state` owned (it is returned), `fields` an alias of it at
its last use (a move), the place `fields.mint` consumed by
`minted_expression`'s owned `mint` and re-initialized by the update before
any read of `fields`, and `fields` consumed by the update at its last use.
Core after Perceus (schematic):

```text
let fields = move state
let mint_in = take fields.mint                   -- unique: slot left null
unpack [mint, expression] = minted_expression(move mint_in, span, kind)
let updated = update fields { mint = move mint } -- in place: fields owned, dead after
(move updated, move expression)
```

In M0 the same function copies `ParseFields`, `MintState` and
`SyntaxCounts` and allocates two tuples: five allocations per node. Under the
redesign's types (`SyntaxCounts` a struct) and with this design: none beyond
the node.

**Example: the loop-carried field.**

```blorp
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

`first` is read before the move (a read, then dead). `var edges =
family.edges` is the last use of the place `family.edges` before its write in
the update, no path reads `family.edges` or `family` as a whole in between,
and the loop has no early exit, so it is a take. The appends find a unique
list. The update writes the slot back and moves `family.rows`' new list in,
in place.

### 5.4 What the model subsumes and what it does not

| Shape | Under the model |
| --- | --- |
| condition read blocks the alias move | flat: `b` is released after the condition (decision 3) |
| chain on a reassigned `var`; chained assignment in an arm | flat: `out` is moved at its old value's last use on each path (decision 1) |
| `next = f(x); x = next` on a `var`, with or without a tuple | flat: the reassignment ends `x`'s old value, so its use in the call is a move |
| `var` declared in an arm | flat: `var out = b` is `b`'s last use on that path |
| closure read once, then dead | flat: the closure, and its reference, are released after the call |
| builder stored in a record, then updated through the field | flat: construction moves `b` in, the field is taken out |
| field moved into a loop variable | flat (section 5.3) |
| same-field read in a record update or a later argument | flat (decision 5) |
| two owned records in one call | **one copies**: a clone owns one parameter (section 4.2); not on the flip's path |
| three-level update; list two levels down | flat (field places at any depth) |
| read after hand-off, a simple read in a later statement (`h = b.f(r); n = b.nodes.length()`) | **copies**: that would need the deferred second tier of decision 5; the source can read first |
| read after hand-off inside a branch, or a user call (`state.current_span()`) | **copies**: even the deferred tier would not move it |
| read after hand-off, managed result (`x = b.nodes` after `b.f()`) | **copies**: the read holds a reference to what the call updates; value semantics require it unless the program reads first |
| a borrow of a field still used after the field's update | **copies**: that is the correct value-semantics result |
| a closure that escapes or is stored | **copies**: the sharing is real |
| list elements and union payloads as places | **not modeled**; union constructor reuse stays as it is |
| a value captured by a closure that only reads it | **copies** while the closure lives; capturing a borrow would need a lifetime the language does not have |

### 5.5 Effort, honestly, and the release step

| Piece | Size | Replaces | Risk |
| --- | --- | --- | --- |
| Tuple flattening and multi-value results | medium to large: a new pass, one Core form, Perceus and emitter cases, adapters | Increment 1 retires `tuple_sroa.brp`; increment 2 retires the surviving `tuple_element_producers.brp` behavior | ABI of every tuple-returning function; contained by the ingress check |
| Consuming clones for multi-value results, with simple reads first | small to medium: about 300 to 400 lines changed (section 4.2) | nothing; extends `consume_specialize.brp` | more clones and more emitted C; measured |
| Place analysis and last-use releases for variables | large | Perceus's scope-end release placement and its alias-move special cases | the largest: Perceus is about 25,000 lines and every ownership gate is sensitive to it |
| Field places | medium | `reuse.brp`'s take rules (most of their part of 5,700 lines) | early exits, cancellation and derived borrows (section 7) |
| Simple reads across statements (deferred, not planned) | small | | the restricted form of decision 5 |

The large item has a smaller first form, a pass named `last_use_release`
(`stage_09_core/last_use_release.brp`). Perceus keeps inserting retains and
releases as it does; `last_use_release` then moves each release to just after
its variable's last use on each path, and turns a retain whose matching
release now directly follows the retained use into a move. It is one rule
applied everywhere (Koka's "drop as early as possible"), checked by the
invariant of section 7.6, and it does not need Perceus's internals rewritten
first. Its placement:

- in `fused_late_core_passes()`, directly after the fused ownership and
  Perceus pass; in `late_core_passes()`, directly after `perceus`; in both,
  before `reuse`, so reuse pairs allocations with releases at their final
  positions;
- before `closure` and `resource_management`, which add capture and cleanup
  ownership of their own that this pass must not move;
- before `prepare`, so the cancellation plan, built from prepared Core, sees
  the moved releases and pops slots where they now are.

Where a release may go:

- after a variable's last use inside an `if` or `match` arm, it goes into each
  arm: after the last use in arms that use the variable, at the start of
  arms that do not;
- never into the right operand of `and` or `or`, which has no node for the
  path that skips it. A variable whose last use is inside a right operand is
  released after the whole logical expression. This keeps the rule of
  `balance_short_circuit_operands`, from the 2026-09-17 leak in which a
  transfer inside a right operand was charged on the path that skipped it
  (`test_short_circuit_operand_ownership.brp`);
- never into a loop body or a lambda from outside;
- never above the last use of a borrow derived from the variable (section
  5.3).

Folding the analysis into Perceus itself is then the cleanup, and fits the
Core rewrite when it comes.

**Clones and the place analysis decide last use once.** Consuming clones stay
(section 4.2), and today consume-specialization decides last use with its own
walk ("precise through bindings, sequences, branches, match results and call
arguments and conservative everywhere else"). Two notions of last use would
drift: the walk could retarget a call the analysis treats as live, or miss
one it treats as a move. So increment 4 makes the walk read the analysis:

- the place analysis runs before consume-specialization, once per original
  function. Its uses, versions and liveness are properties of the body, not
  of which parameter is owned, so a clone, whose body is the original's,
  shares them;
- move and take decisions are not shared, because they depend on whether the
  root is owned. In the original a borrowed `state` at its last use is not a
  move; in the clone `ParseState`'s `state` is owned, so the same use is a
  move, and so is the use of an alias of it such as `fields`. Moves are
  derived per clone, seeded from the parameter its `ConsumingClone` origin
  owns. This is what lets a clone retarget onward, which the
  recursive-descent chain depends on;
- a call is retargeted to a clone exactly when the clone's (or original's)
  decisions mark the argument's use a move (decision 1). This includes the
  `var` cases the walk misses today (`next = f(x); x = next`) and, from
  increment 5, field-path moves: a taken `fields.mint` passed at its last
  use is retargeted to `minted_expression`'s clone. It excludes nothing the
  walk accepts, since the walk is conservative where the analysis is not;
- `last_use_release`, after Perceus, recomputes the same analysis from the
  same module over post-Perceus Core, where borrows are exact. An argument
  retargeted to a clone that turns out to be live there gets a retain from
  Perceus: imprecision costs a copy, never correctness, as today. Under
  `--check-invariants`, after `last_use_release` (not after Perceus, which
  still retains the `var` cases until `last_use_release` turns each
  retain-then-release into a move), a retargeted argument that is not a move
  is reported, so a disagreement shows as a test failure rather than as a
  silent copy.

This is the ownership rework that was expected with the compiler rewrite,
done now in `stage_09_core` because the discovery flip needs it. Each piece is
a separate pass or table with a stated input, so the rewritten Core can take
it as it is.

### 5.6 Addendum: SSA as the foundation for increment 4

Keith asked whether increment 4 should rest on SSA. Core is already mostly
SSA: immutable binders are single-assignment, and `ssa.brp` renames a
straight-line `var` into versioned lets. A `var` assigned under an `if` or
`match`, or in a loop, stays a mutable `LetExpr` with `AssignExpr` writes,
because Core has no join-point (phi) or loop-carried-parameter form
(`ssa.brp`: "lowering them requires phi/loop-carried state rather than
lexical renaming"). Increment 4's rules ("a `var` write ends the old value",
liveness across a loop's back edge) are SSA liveness, computed over
structured control flow without materializing the versions.

**Option A: full SSA for `var`s in Core.** Every `var` becomes versions; a
branch that assigns it yields the new versions at its join; a loop that
assigns it carries them as loop parameters.

- *Branches* need no new form: increment 2's multi-values already are join
  points. `if c: x = a else: y = b` becomes `unpack [x1, y1] = if c: (a, y0)
  else: (x0, b)`.
- *Loops* do. `TailrecLoopExpr(params, type, body)` with `TailrecRecurExpr`
  is already a loop with carried parameters, but only for a whole function
  body. Core has 14 loop forms (`WhileExpr`, nine `For…Expr` forms,
  `ConcurrentlyLoopExpr` and its pre-closure form, and the two tail-recursion
  loops). Each would need carried parameters, a `continue` that passes them,
  and a `break` that yields them, or all would be lowered to one general
  loop-with-parameters form.
- *Passes that change.* `AssignExpr` is constructed or matched at 153 sites in
  33 files of stages 08 to 10. The largest: `reuse.brp` (20 sites, 5,700
  lines), `emit.brp` (13), `perceus/borrowed.brp` (10), `flatten.brp` (9),
  `lower.brp` (8), `perceus/mutable.brp` (8), `traverse.brp`, `closure.brp`,
  `perceus/results_and_loops.brp` and `consume_specialize.brp` (7 each),
  `dce.brp` (6), `ir.brp` and `prepare.brp` (5), `perceus/uses.brp`,
  `cancellation_plan.brp` and `record_update.brp` (4 each). Mutable `let`s
  (`is_mutable`) are handled in about 15 of the same files (39 sites in
  `perceus/results_and_loops.brp` alone). `perceus/mutable.brp` (4,803 lines)
  exists only for mutable locals. Under A, the passes after `ssa` would see no
  `AssignExpr` and no mutable `let`, so most of that handling would be
  deleted. But every loop form's handling in every pass that walks loops
  (Perceus balancing, `closure`, `resource_management`, `cancellation_plan`,
  `prepare`, `emit`) would change to carried parameters, and the emitter would
  translate them back into C assignments (out of SSA). Rough size: thousands
  of lines touched in ten or more passes, with `perceus/mutable.brp` replaced
  rather than patched.
- *Risk.* Cancellation cleanup slots are the largest. A cleanup frame records
  the value it was pushed with, so today "a function whose body rebinds its
  parameters (a self-tail call lowered to a loop) gets no entry slots"
  (`OWNERSHIP_MODEL.md`; `expr_rebinds_parameter` in
  `cancellation_plan.brp`). Under A every loop-carried managed `var` is a
  rebound loop parameter, so the slot protocol would have to be redesigned
  (frames that point at a carried variable's storage), in the same area as
  the open `cancelled-loop-var-record-leaks` leak. Early exits change shape:
  `break` and `continue` carry values, and `?=` and resource cleanup exits
  must pass every live version to their targets. Resource scopes (`with`,
  `ResourceScopeExpr`) would need their bodies' carried values threaded
  through cleanup.
- *What A simplifies beyond ownership.* Mutable-local handling in `reuse`
  (the `x = { x | ... }` and refilled-slot rules), `record_update` (its rule
  for the target of `x = { x | ... }`), consume-specialization's
  `x = f(x)` and destination-forwarding rules, `dce` (dead stores become dead
  lets) and `closure` (no mutable captures to reject late). It would make
  Core-level CSE and code motion possible, but Blorp has none today, and the
  C compiler already performs them on the emitted C (clang's own SSA). The
  remaining value is in what clang cannot see: reference-count operations and
  in-place updates, which is this document's subject, and which B already
  covers.

**Option B: analysis-only versions.** The place analysis versions each `var`
internally (each write starts a new value; a join merges the values reaching
it; a loop's back edge carries the value live at the loop's end) and computes
dominance on Core's structured control flow, where it is nesting plus
sequence order. Core is unchanged.

- *Passes that change:* the new analysis, consume-specialization (reads its
  liveness, section 5.5) and `last_use_release`. The versioning part is a few
  hundred lines of the analysis.
- *Risk:* unchanged from section 5.5. Cancellation slots, early exits and
  resource scopes keep their current Core forms; the analysis only treats
  them as edges.
- *Carry-over to A:* the decision logic (moves, takes, derived borrows, the
  release placement and its rules for `and`/`or`, loops and lambdas) depends
  only on uses, liveness and dominance, so it carries over unchanged; under A
  the versioning part would be deleted, because Core would provide the
  versions. Nothing in B has to be undone.
- *The deferred second tier of simple reads* (section 5.3): under either
  option its conditions reduce to dominance plus "no write between", which
  versions give. Field reads and `length`/`is_empty` are total, effect-free
  and constant-time, so they are speculatable. B's internal versions
  suffice, so A is not needed for it either.

**Recommendation: B.** It gives increment 4 exactly the liveness it needs
without changing Core's forms, it keeps increment 4's scope and risk as
estimated, and its decision logic carries over if Core moves to A. A is a
Core-wide representation change. It would gate the discovery flip on
redesigning the cancellation slot protocol for loop-carried values, and its
benefits beyond ownership are small while clang already does CSE and code
motion. A belongs in the Core rewrite, designed in from the start. There, the
loop-with-parameters form can be built together with a slot protocol for
carried values, and increment 2's multi-values already supply the branch
join points.

**Effect on section 9.** None under B: increment 4's estimate already
assumes analysis-only liveness. Under A, increment 4 would grow from "large"
to a Core-wide change touching the 33 files above plus every loop form, and
the flip would wait on it.

**Found while reading `ssa.brp`:** `substitute_var` matches a variable by
spelling (`variable.name == old_name`), not by its identity, so two bindings
that share a spelling could be confused. It is outside this design; record
it with the Core id migration.

## 6. Allocation lifecycle cost

Section 2.4 splits one allocation's cost: about 500 instructions and 70
cycles in libc's allocator, about 70 instructions and 20 cycles in generated
code and runtime glue. What belongs where:

**In scope here, by removing the lifecycle entirely:** value tuples (no
allocation), moves and last-use releases (no reference-count traffic), owned
parameters and field places (no copies). These remove the whole cost, not a
part of it.

**Small emitted-code items, done where the code changes anyway:**

- A boxed tuple at a sink is made by a fixed-arity maker (`blorp_tuple_new2`,
  `3`, `4`) that sets the release mask in the same call, instead of the
  variadic `blorp_tuple_new` and a separate `blorp_tuple_set_rc`.
- A final release whose static type is known could call that type's destructor
  directly instead of looking it up by `destructor_id`. This saves an
  indirect branch per object freed, which shows in cycles more than in
  instructions; it is its own small change with its own measurement, not part
  of these increments.

**Separate runtime tasks, not designed here:**

- **The allocator.** The mimalloc pilot measured −37% instructions on the
  self-compile; Keith stopped at the pilot and prefers a system package if it
  is adopted. Nothing here assumes or proposes allocator work.
- **Non-atomic counts for objects one thread owns.** Lean 4's runtime keeps a
  positive count for objects only one thread can reach and a negative one for
  shared objects, and marks an object graph shared when it crosses to a task.
  Blorp's thread crossings are all explicit (task capture, channel send,
  `concurrent` blocks, `detach`), so the scheme fits. It needs a marking walk
  at those points and a TSan gate. In instructions the saving is small (an
  atomic pair is 7 instructions); in cycles it is larger. Deferred until
  after the allocator decision (section 1).
- **Arenas for syntax trees.** The discovery ledger's item; a region
  allocation design, not an ownership one.

## 7. Soundness

### 7.1 Value semantics

Every in-place update stays behind a runtime uniqueness check. A move never
creates an alias; a use that is not the last one retains; a shared value
copies on update; a derived borrow keeps its root's value alive and
unchanged (section 5.3). The cases the tests pin (section 8): `(b, b)`; the
original read after handing a copy on (`b2 = b.grow()` then
`b.rows.length()`); `n = b.nodes` then an update of `b.nodes` then
`n.length()`; a boxed tuple from a list destructured and an element updated
(the list is unchanged); a field moved out and an early exit inside the
window (the record still holds the field afterwards); a `var` tuple in a loop
with a `continue`.

### 7.2 Cancellation cleanup slots

The rules in `OWNERSHIP_MODEL.md` ("Cancellation Cleanup Slots", as changed by
`5d3e3fcbb` and `0d9bdef50`) apply to elements unchanged:

- An `UnpackLetExpr` binder is a local bound to an owned call result; it gets
  a slot by the planner's rule for any such local. No cancellation point falls
  between a callee's return and the binding, because the binding's value is
  the call itself, or a multi-value context ending in one (section 3.3).
- A multi-value hands each element on, as a single returned local does: its
  slot is popped.
- A clone's owned parameter, including a clone of a tuple-returning
  function, is handed over by the caller, who pops its slot; the callee
  pushes its own at entry when it can be cancelled before handing the
  reference on. This is today's rule (`5d3e3fcbb`), unchanged; each clone is
  its own function, so `DisagreeingUserCallContract` holds as today.
- Releasing at last use pops a slot earlier; a local whose reference is handed
  on before any cancellation point gets no slot. This also settles
  `caller-pushes-then-pops-handed-over-argument.md`.
- A field taken out of a record: the taken value is an owned local with its
  own slot when a cancellation point falls in the window (a loop's checkpoint,
  a park); the record's slot is null, and field release is null-safe on
  every path, including cancellation (as for today's take). Today's hoisted
  take refuses any cancellation point in its window; with the taken value
  tracked by its own slot that restriction is no longer needed, and the
  ASan tests in section 8 must show it.

**Prerequisite of increment 3.** `cancelled-loop-var-record-leaks.md` is an
open leak in exactly this area: a record `var` reassigned in a loop that parks
leaks when cancelled, and it already reproduces with `(table, id) =
table.intern(w)` in a loop. Clones of tuple-returning functions make more
functions thread owned records through loops, so the leak is fixed before
increment 3 lands,
as the parked branch was blocked on the parameter slot fix.

### 7.3 Early exits

`break`, `continue`, `?=`, resource cleanup exits and tail-recursion jumps are
edges of the place analysis like any other. A variable live on an exit edge is
released on that edge; a field moved out and not re-initialized on an exit
edge on which the base record survives demotes the move (decision 4). No
read is hoisted across statements at all (decision 5). A tail-recursion
loop rebinds its parameters, so a parameter's entry slot rule (no entry slots
when the body rebinds parameters) is unchanged.

### 7.4 Evaluation order

Blorp's purity does not make arbitrary reordering invisible: pure code can
diverge or overflow the stack, and a `debug:` block in a pure function prints
in `--debug` builds and under `blorp test`. So decision 6 moves only simple
reads, which call no user function: they cannot diverge, overflow, print or
fail. Reordering happens only within one call's arguments, one multi-value's
elements, or one record update's replacements, where every operand is
evaluated anyway, so evaluating a simple read first changes nothing but the
order of two reads. No read is moved across statements (that tier is
deferred, section 5.3). Everything else keeps its written left-to-right
order. A multi-value's elements are evaluated
left to right into temporaries before the struct is built (section 3.5).

### 7.5 The stage-2 fixpoint and the bootstrap

`bin/blorp` is linked from C the pinned bootstrap emitted, so it keeps
today's ABI and ownership until a rotation; these changes reach the compiler's
own speed through a stage-2 build, which is also what the flip ceiling
measures (`benchmarks/self_compile_measure --stage2`). Each increment that
changes emitted C proves a fixpoint: the stage-2 compiler compiles the
compiler to C, a stage-3 compiler is built from that C, and stage 3's output
equals stage 2's byte for byte. No repository tool does this today; the first
increment adds it as a script. Rotation stays a separate, coordinated step.

### 7.6 Invariants

- After flattening, always on: a `TupleType` only in a multi-value context
  (section 3.3); a `TupleFieldExpr` only of a `BoxedTupleType`.
- After `last_use_release`, under `--check-invariants`: no owned variable is
  released later than the point after its last use on a path where it is dead
  (the garbage-free property), except where a right operand of `and` or `or`
  holds that last use; no release of a variable and no take of a field place
  before the last use of any borrow derived from it; no read of a place in a
  moved state.
- Existing invariants unchanged: every owned value transferred, consumed,
  retained or dropped exactly once; no borrowed alias across an owning
  boundary without a retain.

## 8. Test plan

**Allocation fixtures (flat versus growing).**
`blorp/test/runtime/fixture/consume_owned_threading_shapes.brp` and
`consume_owned_nested_field_shapes.brp` already report `PASS` or `FAIL` per
shape by comparing allocations at 1,000 and 10,000 rows, run by
`test_alloc_oracle_blorp_level.sh`. Each increment adds the shapes it makes
flat:

- the probe shapes of appendix A: a scalar pair from an opaque body, a record
  pair, the mint pair over a mint pair, recursive descent, a builder in a
  tuple, two owned records, three-level update, list two levels down, dead
  alias then update, `next = f(x); x = next` on a `var`;
- every shape of section 5.1, moved from
  `blorp/test/compiler_new/tools/builder_rule_probe.brp` (which depends on the
  discovery tables that M6 deletes) into the runtime fixture, written against
  a plain record. The read-after-hand-off shape (a simple read in a later
  statement) is pinned as copying, with its count, beside its source fix
  (reading first) pinned as flat, so a later decision on the deferred tier
  starts from a recorded baseline;
- the parked branch's nested-field shapes, as they are;
- the one-call interning shape of section 4.5 (hit and miss arms, the
  `state.module` read in the second element, a `var` caller), with its
  tuple-free controls.

**Re-boxing fixtures (section 3.1).** A fixture whose allocations must equal
today's exactly, not merely stay flat: `for p in pairs: out = out.append(p)`;
`Some(p) => p` stored into a list later; a generic `push[T](xs, x: T)` at
`T = (A, B)` called with a list element; a function returning `pairs[0]` whose
result is stored. Each counts the boxes the flattening pass built from
another box's projections, which must be 0.

**Instruction fixtures (copies hidden from allocation counts).** A copy into a
reused buffer, or memmove inside a COW path, does not show in allocation
counts. A retained benchmark, `benchmarks/ownership_shapes/`, runs each
fixture shape at two sizes under `/usr/bin/time -l` and checks that
instructions per call do not grow with the row count (a ratio of about 1 for a
flat shape, about 3 when the rows triple for a copying one), beside each
shape's tuple-free control from appendix A. It reports instructions per call
against the control, which is the claim each increment makes.

**Value-semantics tests** (`blorp/test/runtime/`): the cases of section 7.1,
each checking the values read after the update, not only counts; tuple
equality and hashing unchanged; `same_object` on tuples is `False`,
`is_unique` is `True` and `refcount` is 0.

**Derived-borrow test under ASan.** `n = b.nodes; b2 = { b | nodes =
b.nodes.append(1) }; n.length()`, and the same with a `BorrowLetExpr`-shaped
alias of `b` itself read after `b`'s last direct use, each checking the
values read (the old length; the old contents), run under `bin/blorp run
--no-format --sanitize`: a take or a release placed before the borrow's last
use is a use-after-free there.

**Cancellation tests** (`blorp/test/runtime/memory/leak_check_baselines/`,
beside `let_alias_cancelled_sleep.brp`), each run under the leak check and
under ASan, because the leak gate cannot see a double release:

- a task that unpacks a multi-value and parks before handing an element on;
- a task parked inside the window of a taken field (the loop-carried field
  shape with a `sleep` in the loop);
- a clone of a tuple-returning function that parks before using its owned
  parameter;
- the `cancelled-loop-var-record-leaks` shapes, including `(table, id) =
  table.intern(w)` in a loop, after their fix.

**Core and emitter tests.** `test_core_*` suites for the flattening rules
(each row of the section 3.4 table, before and after Core), the ingress check
(a `TupleType` outside a multi-value context is an internal error), the
clone extension (candidacy for a result element of the parameter's type, the
benefit of an update inside an element, the walk over elements and
`UnpackLetExpr` binders, contract parity for result elements: an original's
contract for a parameter placed in a result is the same before and after
flattening, and the list of contracts increment 1 changes, which is expected
and measured), `simple_reads_first` (it runs before `consume_specialize` and
`record_update_ownership`), the place analysis's decisions
(including derived borrows and `var` writes), the first tier of simple reads
(a simple read in a later argument, element or replacement is evaluated
first; a user call, a managed read or any read in a later statement is not
moved), and `last_use_release`
(releases into arms, never into a right operand of `and` or `or`, never into
a loop body or lambda); emitter pins for the multi-value struct, its naming,
the struct-element-inline case and the adapter for a function used as a
value. The codegen audit fixtures that pin heap tuples are updated in the
increment that changes them, with the new expectation stated.

**End to end.** The M0 prototype (`blorp/test/compiler_new/tools/m0_tree/`
and `m0_tree_cost.brp` on the separate `compiler-new/m0-tree-prototype`
branch, not on `main`) is rebuilt with
each increment's stage-2 compiler and run in the `new` and `scan` modes:
instructions and allocations of the tree parse, against the 6.80 G and 11.38 M
of today. The discovery `tables` stage is measured with the one-call
spelling interning of section 4.5 against the two-call version. The
self-compile is measured with `self_compile_measure --stage2` for
allocations, retired instructions and peak RSS, with the tuple census of
appendix B repeated, including its re-boxing count.

**Gates per increment:** `scripts/compiler-check --changed`, `scripts/test
compiler-blorp`, `scripts/test compiler-core-sanitize`, `scripts/test leak`,
`scripts/test runtime`, the codegen audit, `make hygiene-check`, and the
fixpoint of section 7.5.

## 9. Increments

Each lands on its own with its proof. The sequence is: land the validated
increment 1 pilot; implement multi-value parameters/results (2);
extend consuming clones (3); then implement last-use and place analysis (4).
Re-measure M0 before deciding whether field places (5) are needed. Stored
tuple layout (7) is separate and may follow 2 without waiting for 3-5.
Increment 6 is deferred pending a real-site census. Do not start 2 against
an unmerged version of 1 or treat 1's pilot numbers as a current-main
baseline. The remaining payoffs are estimates from historical counts and
unit costs (section 2.4), not acceptance evidence. If increment 1 is
rejected, revise this sequence before starting 2; it is a prerequisite,
not an optional optimization.

| # | Change | Depends on | Expected payoff | Proof |
| --- | --- | --- | --- | --- |
| 1 | **Local/match tuple flattening, validated but unmerged.** `tuple_flatten.brp` flattens `match` subjects and immutable locals built from tuples and only taken apart. A `var` tuple, a local used whole, and an arm-built local remain boxed; the call-expansion behavior moves from `tuple_sroa.brp` to `tuple_element_producers.brp` (section 9.1). | none | Earlier tuple census: −1.11 M tuple containers; later matched self-compile: −1.36 M total allocations and −0.75 G instructions. These are distinct comparisons, neither on current `main`. | Pilot report and fixtures on `core/local-tuples-never-allocate`; recheck on integration base before landing. |
| 2 | **Multi-value results.** `UnpackLetExpr`, flattened parameters, struct returns, boxed tuples at sinks by type position, the box-keeping rules, adapters for function values, the ingress check, identity builtins and their documentation; `tuple_element_producers.brp`'s call expansion deleted. | 1 | M0: −3.3 M tuple allocations, −1.7 to −2.0 G of 6.80 G. Self-compile: about −0.28 M. Probes: an opaque `(Int, Int)` from 574 to about 10 instructions; `record_pair` from 2 allocations to 1. | probes; M0 `new`; re-boxing fixtures; codegen audit updates |
| 3 | **Consuming clones for multi-value results, with simple reads first.** Section 4.2: candidacy for a result element of the parameter's record type, the walk over elements and `UnpackLetExpr` binders, the benefit and record-update rule 2 for an update inside an element, contract parity for originals, simple reads first within one call, result or update. Requires the `cancelled-loop-var-record-leaks` fix first. | 2 | M0: the `ParseFields` copies reached through immutable binders and call results, the recursive-descent chain of section 4.4, part of about 1.2 M; proven with fixtures written that way, not with the `var`-loop probes. Self-compile: more clones and more emitted C, measured (the first input to question 1's revisit criterion). Acceptance: stage-2 instructions and allocations of increment 3 alone rise by no more than 0.3% (the Perceus cleanup floor in `PERCEUS_CLEANUP_ISSUES.md`), and increments 3 and 4 together lower them. | a recursive-descent fixture over immutable binders; clone count and C bytes; a fixture row pinning the two-owned shape copying exactly one record per call; self-compile stage 2 |
| 4 | **Place analysis and last-use releases for variables.** The analysis table with derived borrows and `var` writes; consume-specialization reads its liveness in place of its own walk; `last_use_release` after Perceus. | 3 | With increments 2 and 3: the rest of the `ParseFields` copies (about 1.2 M in all, −0.6 to −0.7 G); spelling interning's whole +1.06 M allocations and +1.7 G, causes (a) and (b) (section 4.5); `cell_pair`, `pushed` and `step` reached as clones from their `var` loops; `record_pair` to no allocation; builder in a tuple from quadratic to linear (77,931 to about 40 instructions per call at 100,000 rows); two owned records from quadratic to linear, one `Cell` copy per call remaining; the dead-alias probe from 40,001 to about 15; the variable shapes of section 5.1. Self-compile: fewer reference-count operations; measured, no estimate. | fixture rows; the `tables` stage; ASan derived-borrow test; the garbage-free invariant |
| 5 | **Field places.** Moves out of field paths at any depth, re-initialization by update, demotion rules; `reuse.brp`'s take rules deleted. M0 is re-measured after increment 4 before this starts (section 1). | 4 | M0: the `MintState` copies, about −1.2 M allocations, −0.6 to −0.7 G, which needs a field-path move (`fields.mint`) to count for retargeting to `minted_expression`'s clone. Probes: three-level update 1 to 0 per call; list two levels down quadratic to flat; field moved into a loop variable flat; `record-update-same-field-read` (1,005 / 10,005 to flat), by simple reads first within one update applied to field places. | fixture rows, including one in which a taken field is passed to and retargeted to a clone; ASan cancellation tests |
| 6 | **Deferred, not planned: simple reads hoisted across statements** (the deferred design of decision 5). Taken up only if a census of real sites shows it is needed. | 5 | Today's evidence is one issue, `read-after-builder-handoff-copies`, whose source fix is to read before handing off. | a census of sites first |
| 7 | **Stored tuples** (not on the flip's path): inline tuple fields in records and typed unions, inline `List[(A, B)]` storage (S5), an unboxed `Option` of a multi-value, and `for (i, x) in xs.enumerate()` without a list. | 2 | Self-compile: the 1.05 M stored and 0.21 M optional tuples, measured per step. | per step |

**What the flip can expect.** Of the M0 tree parse's 9.06 M plumbing
allocations, about 6.8 M go: 3.3 M with increment 2, 1.2 M (`ParseFields`)
with increments 3 and 4, 1.2 M (`MintState`) with increment 5, and 1.2 M
(`SyntaxCounts`) by the redesign's own `struct`, with no compiler work
(section 2.1). The total, and so the table below, is unchanged by that last
attribution; increment 5's share falls from about a third to about a sixth.
What remains is about 2.3 M: the other 0.8 M of the 4.3 M record and box
copies and the 1.46 M M0 could not attribute. If the struct boxes inside the
mint tuples (`NameUse` and `Binder`, up to about 0.8 M) are among those, they
go with increment 2 and the remainder is about 1.5 M.

| | Low removal | Central | High removal |
| --- | ---: | ---: | ---: |
| Allocations removed | 6.8 M | 6.8 M | 7.6 M |
| Cost per allocation | 510 | 600 | 600 |
| Instructions removed | 3.5 G | 4.1 G | 4.6 G |
| Tree parse of the bodies (historical M0: 6.80 G) | 3.3 G | 2.7 G | 2.2 G |
| Tree stage (historical M0: 9.12 G; then-current stage: 3.25 G) | 5.7 G | 5.0 G | 4.6 G |
| Over that stage | +2.4 G | +1.8 G | +1.3 G |
| Share of the historical 405 G self-compile | +0.59% | +0.44% | +0.33% |

The low case prices each allocation at M0's isolated probe (510
instructions); the central and high cases at M0's whole-parse average (600),
which is measured on this workload; the high case also removes the up to
0.8 M struct boxes inside tuples. Extended clones in place of inferred
ownership leave this table unchanged: every M0 removal it counts needs only
one owned parameter per function (section 4.2), so nothing here depended on
inference. All three were within the +1% ceiling of that older baseline
before the adapter's estimated, unmeasured saving. This table is a
hypothesis for the remaining work, not a prediction against the later
204.6 G baseline. Replace each row with a matched measurement before
deciding to proceed.

**Found while measuring, outside this design:**

- A three-level nested record update copies one record per call, and a list
  appended two levels down copies the list per call (quadratic); both are
  fixed by increment 5 but exist today without any tuple.
- A `var` reassigned from a temporary (`next = f(x); x = next`) is not handed
  to the call; fixed by increment 4.
- `List.enumerate` materializes a list of tuples: 0.44 M tuples per
  self-compile, and association lists `List[(K, V)]` in the compiler's own
  code about 0.6 M more.
- The M0 report's "missing projected callable" when constructing a generic
  union across modules is still not minimized.

### 9.1 Increment 1 pilot and remaining boundary

The unmerged `core/local-tuples-never-allocate` branch implements
`tuple_flatten.brp` after the existing early-Core passes. It flattens tuple
`match` subjects and immutable local tuples that are only taken apart. It
preserves the box for a whole-value use, a `var` tuple, or an arm-built
local. In particular, `(a, b) = match ...` with tuple-building arms still
needs the multi-value binding in increment 2; the original estimate of
1.5 M removable tuples counted about 0.45 M of these arm-built tuples too
early. The earlier pilot census found a re-boxing count of zero; that
count was not repeated in the later matched comparison. Its `-O2`
fixpoint holds.

The branch's retained report is
`benchmarks/results/tuple_flatten_increment1_2026-10-02.md` (read it with
`git show core/local-tuples-never-allocate:benchmarks/results/tuple_flatten_increment1_2026-10-02.md`
until the branch lands). In its later matched comparison against
`deb198af83a62`, total self-compile allocations changed from 215,010,542
to 213,645,604 (−1,364,938), and median retired instructions from
204,631,122,930 to 203,876,898,519 (−754,224,411). The earlier tuple
census measured 3,446,082 to 2,336,386 tuple allocations (−1,109,696)
against a different frozen revision; that exact tuple count was not
remeasured in the later comparison. These numbers establish a promising
pilot, not a result on `main` or proof of increments 2-7.

Before landing, review the branch against the then-current `main`, repeat
its targeted and ownership-sensitive gates, and preserve its measured
baseline/candidate provenance. Once landed, remove increment 1 from this
open-work plan and link the retained benchmark report; start increment 2
from that integrated baseline.

## Appendix A. Probe programs and commands

The pilot branch retains the probes in `benchmarks/ownership_shapes/`;
they are not on `main` yet. In
`value_tuple_probe.brp` each mode runs one shape `count` times, and each tuple
shape has a control doing the same work without a tuple.

```blorp
record Cell {
	count: Int,
	label: String
}


record Counts {
	expressions: Int,
	statements: Int
}


record Mint {
	module: Int,
	counts: Counts
}


record State {
	cursor: Int,
	mint: Mint,
	diagnostics: List[Int]
}


opaque type ParseState = State


record Node {
	id: Int,
	span: Int,
	kind: Int
}


record Builder {
	rows: List[Int],
	edges: List[Int]
}


-- (Int, Int) from a body tuple_sroa cannot summarize (a loop).
pure func pair_of_loop(value: Int) -> (Int, Int):
	var total: Int = value

	for i in 0..2:
		total += i

	(total, value)


pure func cell_pair(cell: Cell) -> (Cell, Int):
	({ cell | count = cell.count + 1 }, cell.count)


-- The redesign's section 3.15 mint: (Mint, Node).
pure func minted(mint: Mint, span: Int, kind: Int) -> (Mint, Node):
	id: Int = mint.counts.expressions
	(
		{ mint | counts = { mint.counts | expressions = id + 1 } },
		{id = id, span = span, kind = kind},
	)


-- The redesign's section 3.16 finish: (ParseState, Node) over the mint.
pure func finished(state: ParseState, span: Int, kind: Int) -> (ParseState, Node):
	fields: State = from_opaque ParseState(state)
	(mint, node) = fields.mint.minted(span, kind)
	(into_opaque ParseState({ fields | mint = mint }), node)


-- Recursive descent: a right-nested sum of `depth` leaves, each a mint.
pure func parse_sum(state: ParseState, depth: Int) -> (ParseState, Node):
	(after_leaf, leaf) = state.advanced().finished(depth, 1)

	if depth == 0:
		(after_leaf, leaf)
	else:
		(after_rest, rest) = after_leaf.parse_sum(depth - 1)
		after_rest.finished(leaf.id + rest.id, 2)


pure func pushed(builder: Builder, value: Int) -> (Builder, Int):
	({ builder | rows = builder.rows.append(value) }, builder.rows.length())


pure func step(builder: Builder, cell: Cell, value: Int) -> (Builder, Cell):
	({ builder | rows = builder.rows.append(value) }, { cell | count = cell.count + 1 })
```

The controls are `bumped(cell) -> Cell`, a `counted(state) -> ParseState`
that updates the same counter with the node built beside it,
`pushed_only(builder, value) -> Builder`, and one record holding the builder
and the cell. The tuple loops are `(next, x) = f(...)` then `var = next`, as in
the parser.

Commands, from the worktree root, `bin/blorp` `FRESH` at `9172b35e0`:

```bash
S=<scratch>/value_tuples
bin/blorp compile --no-format -o $S/probe.c $S/value_tuple_probe.brp
clang -x c $S/probe.c -O2 -fwrapv -w -lm -lpthread -o $S/probe
clang -x c $S/probe.c -O2 -fwrapv -w -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread -o $S/probe_diag
BLORP_MEMORY_STATS=1 $S/probe_diag <mode> 100000         # allocations
/usr/bin/time -l $S/probe <mode> 100000                   # instructions, three runs
```

Raw medians at 100,000 calls (instructions retired, whole process):

| Mode | Instructions | Allocations |
| --- | ---: | ---: |
| `empty` | 18,699,134 | 0 |
| `pair_inline` | 18,465,667 | 0 |
| `pair_call` | 76,073,804 | 100,000 |
| `record_alone` | 19,234,636 | 1 |
| `record_pair` | 129,017,014 | 200,001 |
| `mint_control` | 120,007,097 | 200,020 |
| `mint_kept` | 335,618,363 | 600,020 |
| `descent` (10,000 calls of depth 9) | 655,487,588 | 1,250,004 |
| `builder_alone` | 22,552,458 | 17 |
| `builder_pair` | 7,811,790,729 | 300,001 |
| `two_owned_record` | 7,706,659,632 | 100,003 |
| `two_owned` | 7,860,331,276 | 400,002 |

The interning probe of section 4.5 (`intern_probe.brp`) has the same arms as
`interned_spelling` over a record of two `List[Int]` (`appended` updates both
lists), misses on three of every four calls, and runs 1,000 and 10,000 calls
per variant in one process under `BLORP_MEMORY_STATS=1`. Its variants:

```blorp
-- given: the shape of interned_spelling
pure func interned_given(spellings: Spellings, value: Int) -> (Spellings, Int):
	state: Table = from_opaque Spellings(spellings)

	if value % 4 != 0:
		(into_opaque Spellings(appended(state, value)), state.texts.length())
	else:
		(spellings, 0)


-- no tuple; called both as `next = ...; spellings = next` and as
-- `spellings = interned_alone(spellings, i)`
pure func interned_alone(spellings: Spellings, value: Int) -> Spellings:
	state: Table = from_opaque Spellings(spellings)

	if value % 4 != 0:
		into_opaque Spellings(appended(state, value))
	else:
		spellings
```

plus `given` without the read of `state` in the second element, and a variant
whose hit arm returns `into_opaque Spellings(state)`. In the generated C of
`given`, the caller emits `blorp_retain(spellings)` before the call and
releases its reference at the reassignment, and the callee's miss arm calls
`appended`'s borrowing original with the retained alias; in the
`spellings = interned_alone(...)` form the caller calls the consuming clone
and the clone's miss arm releases `spellings` before handing `state` on.

The allocation lifecycle numbers of section 2.4 come from a C loop of
`malloc(40)`, a store, a read and `free`, with and without an atomic
increment and decrement, 10,000,000 iterations, `-O2`, under `/usr/bin/time
-l`.

## Appendix B. Self-compile tuple census

Method: a copy of `runtime.c` whose `blorp_tuple_new` counts calls by arity
was linked with `bin/blorp`'s own split objects (`make` at `9172b35e0`) and
compiled the compiler (`compile --no-format blorp/src/main.brp`): 3,446,785
tuples, 397.7 G instructions (this binary's compiler C is built at `-O0`),
byte-identical output C. For attribution, the compiler's C was emitted with
`--profile-mode calls` (whose metadata maps C symbols to Blorp functions),
`blorp_tuple_new` was patched to count by return address, and the result was
built at `-O0` so no allocation is attributed to an inlining caller; the run
allocated the same 3,446,785 tuples. Sites with at least 500 allocations,
3,425,121 tuples in all, were attributed to their functions and each function
was classified by its source shape. The largest:

| Tuples | Function | Shape |
| ---: | --- | --- |
| 425,523 | `module_view.bound_import_request_local_name` | tuple built by a `match` with or-patterns, destructured |
| 196,232 | `ctfe/context.ctfe_context_from_decls_in_domain` | `List[(Id, Function)]` append |
| 190,471 | `mono.core_mono_type_equal` | `match (left, right):` with or-patterns |
| 172,226 | `mono_specialize.collect_call_substitution` | three-element `match` subject |
| 163,165 | `perceus/results_and_loops.call_single_direct_consume` | `match` subject |
| 162,438 | `ctfe/env.ctfe_replace_binding` | `List[(String, Binding)]` append |
| 155,131 | `mono.core_mono_substitution_value_equal` | `match` subject |
| 142,531 | `List.enumerate` over `Int` | stored |
| 97,416 | `List.enumerate` over `CoreDecl` | stored |
| 88,972 | `List.enumerate` over `CoreUnionVariant` | stored |
| 83,525 | `mono.add_substitution` | `List[(String, Type)]` append |
| 74,584 | `accepted_global_authority.graph_selective_global_targets` | `Option[(String, ModuleId, List[DefinitionId])]` result |
| 74,584 | `accepted_callable_authority.graph_selective_callable_targets` | `Option[(...)]` result |
| 72,880 | `ir.core_type_equal` | `match` subject |
| 66,180 | `match_lowering.expand_or_match_case_at` | returned tuple |
| 64,965 | `match_lowering.constructor_pattern_parts` | `Option[(String, List[CorePattern])]` result |
| 64,147 | `consume_specialize.record_update_bound_source` | `match` subject |
| 53,795 | `env.env_mint_def_id` | returned tuple |
