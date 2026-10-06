# Value Tuples and Owned State Hand-off

Status (2026-10-02): increment 1 is implemented; increments 2-5 and 7 are
open. This is the plan of record for non-storage tuple flattening, owned state
through calls, and stored tuple layout. Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md)
before implementing or measuring an increment. Current ownership rules are in
[`OWNERSHIP_MODEL.md`](OWNERSHIP_MODEL.md); struct-key/value dictionary
specialization is retired while [record simplification](FIXED_LAYOUT_ROADMAP.md)
is the active product-layout path.

The measured [increment 1 result](../benchmarks/results/tuple_flatten_increment1_2026-10-02.md)
records its implementation boundary, source/binary provenance, allocation
effect and caveats. The [historical design baseline](../benchmarks/results/value_tuple_design_baseline_2026-10-02.md)
retains the older probes and tuple census. Its self-compile attributed
1,052,834 tuples to list storage and 214,133 to optional results, on a
pre-increment-1 revision; these are context for a new census, not predicted
savings. The M0 tree-parser measurements were made on a separate prototype
branch, against a different compiler baseline; read its retained report with
`git show a8e87c30e:benchmarks/results/discovery_redesign_m0_2026-10-02.md`.
Every proposed change below needs a matched current measurement before a
performance claim.

## Sequence and decisions

| Increment | Scope | Depends on | Decision before landing |
| --- | --- | --- | --- |
| 2 | Multi-value parameters/results and boxes only at defined boundaries | Implemented 1 | Prove the ABI, ownership and re-boxing rules below. |
| 3 | Consuming clones for multi-value results; simple reads first within an expression | 2 | Check clone growth and the stage-2 cost ceiling below. |
| 4 | Place liveness for variables and last-use releases | 3 | Show one notion of last use across clones and Perceus, including derived borrows and cancellation. |
| 5 | Field places and conditional takes | 4; first re-measure M0 | Proceed only if remaining field-copy cost justifies it. |
| 7 | Stored tuples in fields, lists and optional results; `enumerate` without materialization | 2; independent of 3-5 | Fresh dynamic census first; measure each storage boundary separately. |

Increment 6, hoisting simple reads across statements, is deferred until a
census of real sites warrants it. The only recorded example has a natural
source change: read before handing off. The allocator, non-atomic reference
counts, and a full SSA conversion are separate projects. Keep the current
one-owned-parameter consuming-clone scheme; consider inferred ownership only
if clone growth or copies left after increments 4-5 cause a large measured
self-compile difference. The discovery redesign's M6 flip waits on 2-4, and
on 5 only if M0 re-measurement after 4 requires it; earlier redesign steps
can proceed independently. Those dependencies do not turn historical M0
projections into current-main acceptance evidence.

## Increment 2: tuples as values

### Layout and box preservation

Blorp tuples have two to four elements and compare and hash by element. All
source record forms are managed; tuple flattening does not introduce a
separate source-language record representation. After monomorphization, a
tuple that is the whole type of a local, parameter or result is a group of
values. A multi-value result uses a C
struct by value only as ABI transport; it is never a Blorp value or Perceus
variable. A tuple nested inside another type remains a `blorp_Tuple` box
through increment 5: list/set/dictionary slots, record fields, union and
`Option` payloads, closure/task/channel signatures and runtime helpers are
examples. Increment 7 owns the measured storage changes.

A **sink** expects a nested tuple (`xs.append((a, b))`, `Some((a, b))`, a
tuple field); it builds a box from separate elements. A **source** reads a
stored tuple (`xs[i]`, a field, a payload binding or closure parameter);
it keeps its existing box, and element projections borrow from that box.
A box read from a source and later stored whole is retained, never rebuilt.
The flattening pass counts boxes built from another box's projections; the
accepted count is zero for the re-boxing fixtures below.

A parameter used whole at a sink stays boxed. This includes a generic
`push[T](xs: List[T], x: T)` instantiated with tuple `T`. A parameter also
stays boxed when passed whole to another boxed parameter. Decide this with
a least fixpoint over the monomorphized call graph: start tuple parameters
flattened, mark a parameter boxed when its body stores/captures/passes it to
a sink or to a boxed parameter, and repeat until no mark changes. A result
whose every path returns an existing source box unchanged stays boxed.
Lambda bodies keep their closure ABI's boxed tuple parameters/results;
adapters provide the boundary for references to flattened named functions.

A mixed result (some paths build a tuple, others return an existing box)
normally returns a multi-value. A caller storing its box-sourced result may
then allocate where the old code retained the box. Count these re-boxing
paths and their storing call sites; pin one in a fixture. If the census shows
material cost, a function whose callers all store its result may instead
keep a boxed result. Do not silently accept a new allocation as a general
source-to-sink rule.

### Core form and failure boundary

After `tuple_flatten.brp`, `CoreType.TupleType(items)` means a multi-value;
`CoreType.BoxedTupleType(items)` means a runtime tuple box.
`CoreExpr.UnpackLetExpr(binders, value, body, typ, loc)` binds each result
element as a local in element order. `TupleExpr` creates a multi-value only
in a **multi-value context**: a tuple-returning function body, an
`UnpackLetExpr` value, or the value-bearing continuation/arm/body of a
`LetExpr`, `BorrowLetExpr`, `UnpackLetExpr`, `SeqExpr`, `IfExpr`, match,
tail-recursion loop, resource scope, or Perceus `DupExpr`/`DropExpr`.
Tail-recursion jumps produce no value. An exhaustive Perceus-ingress check
classifies every Core form, so a new form cannot silently admit an illegal
`TupleType`. `TupleFieldExpr` reads only `BoxedTupleType`. An illegal form
fails with an internal error naming its function; there is no heap fallback.

Flatten all top-level tuple types, including managed elements and `var`
tuples. A local built from a tuple becomes element locals; one bound to a
call becomes `UnpackLetExpr`. A `var` assignment unpacks to temporaries
before assigning its elements. A flattened parameter expands into element
parameters unless the sink fixpoint keeps it boxed. A whole use at a sink
constructs the one required box. A boxed source remains one binding and its
element reads remain projections. Unused result elements are bound and
released at once. `Void` members are omitted from storage; zero data members
return `Void`, and one returns that member directly. Increment 1 already
handles match subjects and immutable locals built then taken apart; increment
2 adds arm-built locals, calls, parameters, results and the currently boxed
`var` shapes. It also removes the surviving call-expansion behavior in
`tuple_element_producers.brp`.

Function-reference adaptation takes the closure ABI's boxed tuple arguments,
unpacks them, calls the flattened named function, and boxes its result. It
must be a real wrapper: a C function returning a struct is never called
through a pointer declared to return `void*`. The emitter names a result
layout by canonical element types in deterministic first-use order for one
emission. It evaluates elements left to right into temporaries before
constructing the C struct; initializer-list evaluation order is not relied
on. Every member is initialized; no padding is compared, hashed or copied
as bytes. Struct-typed members are inline in this transport.

Each multi-value element transfers ownership as a single result would:
an owned local at last use moves, a borrow retained only when it escapes.
`UnpackLetExpr` call binders own their results; a `TupleExpr` keeps each
element's own fact. A boxed source is borrowed from its container;
projections are `Alias(box)`. Boxing at a sink consumes elements like a
record constructor. Capturing a flattened tuple captures elements; a boxed
one remains one owner. `(b, b)` retains for the second use so updates still
copy a shared record. Perceus balances multi-value branches per element and
never sees a variable of `TupleType`.

Keep the original ownership contract when a parameter is placed in a
multi-value result: treat each result element like the old tuple
constructor's operand. A parameter returned alone stays borrowed and is
retained at the return. Increment 1 intentionally changed contracts for
parameters formerly consumed solely by removed local/match tuples; its
[result](../benchmarks/results/tuple_flatten_increment1_2026-10-02.md)
records them. `same_object`, `is_unique` and `refcount` answer for a tuple as
for other stack values (`False`, `True`, `0`) without boxing, with matching
standard-library comments and Guide text updated in increment 2.

### Increment 2 proof

- Core tests cover each shape above, especially `var`, arm-built and
  call-bound tuples, source-to-sink preservation, the exhaustive ingress
  failure, contract parity, adapters and left-to-right element order.
- Re-boxing fixtures count allocations exactly: a list element appended to
  another list, `Some(p) => p` stored later, generic `push[T]` with tuple
  `T`, and a function returning `pairs[0]` whose result is stored. Each
  records zero boxes rebuilt from source projections. Pin the known mixed
  result's count separately.
- Emitter and codegen-audit fixtures inspect generated C for typed returns,
  inline struct elements and a correctly typed function-value adapter.
  Runtime tests check tuple equality/hash and the three identity builtins.
- Run the direct probe commands in
  [`benchmarks/ownership_shapes/README.md`](../benchmarks/ownership_shapes/README.md)
  before the broader gates. Compare a stage-2 compiler with the integrated
  increment-1 base on frozen identical input; record allocations,
  instructions, peak RSS, generated-C hashes and a fresh tuple census.
  The old M0 and self-compile numbers are hypotheses, not pass criteria.

## Increment 3: owned calls with multi-value results

Keep `ConsumingClone(index, declared_as)`: a clone owns exactly one record
parameter. Extend `function_is_cloneable` when any element of a multi-value
result has that parameter's record type. The benefit fixpoint must see an
in-place update inside a result element; record-update ownership rule 2
must take the clone's parameter when that update is in an element. The
last-use walk evaluates elements in order and tracks `UnpackLetExpr` binders
like `let` locals. Originals keep the contract parity specified above.
Two owned record parameters still leave one copy; that shape is a retained
limit, not a reason to infer every parameter's contract now.

`simple_reads_first` is a Core rewrite after `dce`, before
`consume_specialize` and `record_update_ownership`. Within one call's
arguments, one multi-value's elements or one record update's replacements,
it binds a simple read before a sibling that moves the same place. A simple
read is a field path or total, constant-time `length`/`is_empty` of one,
with an unmanaged result. It never moves a user call, a managed read or a
read across statements. This lets `state.module` be read before an element
updates `state`, without changing which effects or divergences occur.

A cancelled loop that threads state through `(table, id) = table.intern(w)`
no longer leaks (`loop_var_cancelled_sleep`). Prove an immutable-binder
recursive-descent fixture reaches consuming clones through each returned
state. Check `UnpackLetExpr` binder tracking, result-element update benefit,
parity of original contracts, clone count and emitted C bytes. The two-owned
fixture must still copy exactly one record per call. Stage-2 instructions
and allocations for increment 3 alone may rise by no more than 0.3% (the
[Perceus cleanup acceptance ceiling](issues/perceus-frame-stacks-duplicate-traversal-storage.md#acceptance-and-owner));
increments 3 and 4 together must lower them. Measure, rather than assume,
the cost of the extra clones.

## Increment 4: last use of variables

Use one place/liveness analysis specification for consume-specialization
and Perceus. Build its per-function table before consume-specialization,
then recompute after Perceus so `last_use_release` can use exact borrow
facts. A place is a local or parameter, or a field path rooted there;
increment 4 acts on variables, and increment 5 enables field moves. List
elements and union payloads are not places. Keys are resolved binder/value
ids and `CoreFieldRef` ids, never spellings. Occurrence ordinals come from
one fixed traversal; the table is read-only for that function and is not
stored in Core. Core remains structured; the analysis internally versions
each `var` write, merges at joins and follows loop back edges. Full SSA is
not a prerequisite.

Track reads, consuming uses, whole-base uses and writes in evaluation order.
A `var` assignment ends the old value, including on a loop back edge:
`next = f(x); x = next` can hand the old `x` to a consuming clone. Backward
liveness answers whether a value is used again on any path; a forward state
records initialized, moved or maybe moved. At last use a consuming use
moves; a non-last consuming use retains. An owned value not transferred is
released immediately after its last use on each path. A clone shares the
original's uses/liveness but derives move decisions again from its owned
parameter; retarget a call to a clone exactly when that argument is a move.
Delete consume-specialization's separate last-use walk and destination
forwarding once this analysis drives retargeting.

Every derived borrow counts as a use of its root place: `BorrowLetExpr`,
`Alias(owner)`, match payload binders and boxed tuple projections. Before
Perceus, conservatively treat immutable aliases of a variable or field path
as rooted there; after Perceus, use exact borrow facts. In
`n = b.nodes; b2 = { b | nodes = b.nodes.append(1) }; n.length()`, the
later `n` use prevents taking or releasing its root early. Imprecision
demotes a move to a copy, never the reverse.

Introduce `last_use_release` after Perceus and before `reuse`, `closure`,
`resource_management` and `prepare` in both fused and unfused late-Core
pipelines. It places releases in each `if`/match arm after the last use;
an arm that never uses the owner releases at its start. A release never
moves into the right operand of `and`/`or` (the skipped path has no node),
nor into a loop or lambda from outside, nor above the last derived-borrow
use. It can turn a retain followed by its matching release into a move.
Under `--check-invariants`, a retargeted argument that is not a move after
this pass is an error; Perceus may safely retain when its pre-pass view is
conservative.

Prove the `var` hand-off, dead-alias, branch join, cancellation and
short-circuit fixtures. The one-call spelling interning probe must be
measured against the two-call control in the discovery `tables` stage: the
caller's `var` and the callee's alias are separate causes of copying.
Check that no owned variable is released after its final path use except
the specified short-circuit placement. ASan tests must prove that a
derived borrow remains live. Allocation counts and two-size instruction
probes must distinguish flat updates from list-copy growth; measure the
stage-2 self-compile again.

## Increment 5: field places

Re-measure M0 after increment 4 before starting. If field copies still
matter, allow a field path of an owned record to be conditionally taken:
unique record, take the slot and leave it null; shared record, retain the
field. A taken value is an owned local. The field must be re-initialized, or
its base must die, before any later read, whole-base use, derived-borrow use
or exit on which the base survives. Check `break`, `continue`, `?=`, resource
cleanup and tail-recursion edges; otherwise demote the take to a copy.
Reads used by a sibling update obey only increment 3's within-expression
`simple_reads_first` rule. Use the same analysis table and derive field
move decisions for each clone, so a taken `fields.mint` passed into
`minted_expression` can reach its consuming clone. Delete `reuse.brp`'s
per-shape take rules after the replacement is independently validated.

Pin a multi-level record update, list two levels down, a field moved into
a loop `var`, a read of the same field inside an update, and a field passed
to a clone then written back. Check old and new values when a borrow or
shared alias survives. A cancellation point inside a taken-field window
needs its own cleanup slot, a null record slot and null-safe release; run
both leak and ASan tests. The M0 field-copy census, stage-2 instructions,
allocations and peak RSS decide whether the measured improvement justifies
the change. A negative result can park increment 5.

## Increment 7: stored tuples

After increment 2, take a fresh dynamic tuple census on current frozen
input. Classify record and typed-union tuple fields, `List[(A, B)]`,
`Option[(A, B)]`, and `List.enumerate` materialization separately. Count
struct boxes at tuple elements here; S5 owns struct keys/values in erased
dictionaries. The historical 1.05 M stored-list and 0.21 M optional
allocations belong to the older `9172b35e0` census and do not establish a
current payoff.

Consider separate steps for inline tuple fields, inline typed list storage,
an unboxed option/multi-value payload, and `for (i, x) in xs.enumerate()`
without a list. Each step names its runtime representation and ownership
rule, pins generated C and value semantics, runs correctness/leak/sanitizer
gates, and measures stage-2 allocations, instructions and memory against
its immediate parent. Stop or park any step whose dynamic count or net cost
does not justify its complexity. Tuple elements in erased `Set`/`Dict`
storage, other runtime helpers and generic signatures need their own
census; this increment makes no blanket representation promise for them.

## Soundness and common gates

Every in-place update retains a runtime uniqueness check. A non-last use
retains; a shared value copies; a derived borrow keeps its root alive and
unchanged. Value-semantics tests cover `(b, b)`, a read of the original
after an updated copy, a borrowed field read after the base update, a boxed
list tuple whose element is updated, and a `var` tuple across `continue`.
The tests compare values, not only allocation counts.

Cancellation cleanup slots follow
[`OWNERSHIP_MODEL.md`](OWNERSHIP_MODEL.md): an `UnpackLetExpr` call result's
owned binders get local slots; each multi-value element pops its slot when
handed on. A caller handing an owned argument to a clone pops its slot and
the callee pushes its own when cancellation can occur before further
transfer. A taken field has an owned local slot during a cancellation window,
while the record's field slot is null. `break`, `continue`, `?=`, resource
cleanup and tail-recursion jumps are analysis edges. Reordering is restricted
to simple reads among operands that all execute; ordinary left-to-right
source order remains. A pure user call is not assumed safe to move: it may
diverge, overflow the stack or print from `debug:`.

After increment 2, always validate `TupleType` contexts and boxed field
projections at Perceus ingress. After increment 4, under
`--check-invariants`, validate immediate last-use releases, derived-borrow
liveness and no read of a moved place. Existing once-only transfer/retain/
drop and no-unretained-borrow rules remain in force. The targeted test
matrix includes Core/emitter cases, the `PASS`/`FAIL` allocation oracle in
`blorp/test/runtime/test_alloc_oracle_blorp_level.sh` over its
`consume_owned_threading_shapes.brp` and
`consume_owned_nested_field_shapes.brp` fixtures, and two-size instruction
oracles in [`benchmarks/ownership_shapes/`](../benchmarks/ownership_shapes/README.md),
runtime value-semantics cases, ASan derived-borrow and cancellation cases,
leak checks, and codegen-audit fixtures deliberately updated when an
expected box changes. The historical M0 driver lives on the separate
`compiler-new/m0-tree-prototype` branch; if available, rebuild it with
each candidate's stage-2 compiler and compare `new` against `scan` on the
same input. No M0 result substitutes for the current self-compile.

From the worktree root, run the focused fixture and probe commands in the
owning test or benchmark README, then these broader gates for each code
increment (with stage-specific additions above):

```bash
bash blorp/test/runtime/test_alloc_oracle_blorp_level.sh
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test compiler-core-sanitize
scripts/test leak
scripts/test runtime
bash blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh bin/blorp
make hygiene-check
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint
scripts/docker-gate --premerge-gate --platform linux/arm64 -- --no-sanitize
```

`scripts/compiler-fixpoint` proves stage 2 and stage 3 emit byte-identical
C; byte identity against the preceding increment is not expected when the
ABI or layout changes. The pinned bootstrap leaves `bin/blorp`'s own ABI
unchanged until a separate rotation, so compiler-speed claims require a
stage-2 compiler. Use the paired, frozen-input procedure in
[`benchmarks/README.md`](../benchmarks/README.md#self-compile-measurement-protocol)
for allocations, retired instructions, peak RSS and generated-C provenance.
Run compiled binaries serially. A candidate's value/output semantics and
the stage-2/3 fixpoint must match even when its emitted C differs from its
parent. Report raw artifacts, revision/toolchain identity, exact counts and
limitations; do not infer a speedup from the older M0 estimates.

The fixed-arity boxed tuple makers (`blorp_tuple_new2/3/4`) are a separate
measured follow-up only if the residual cost at sinks is material. A direct
destructor call instead of a `destructor_id` lookup is another separate
runtime optimization. Neither is required for increment 2 correctness.
