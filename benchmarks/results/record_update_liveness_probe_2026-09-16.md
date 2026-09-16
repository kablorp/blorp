# R1: does a record update keep the old record alive?

Date: 2026-09-16. Branch `perf/r1-record-update-liveness-probe`, `-O0` build,
base `a6877ebf`, `scripts/compiler-build-status` FRESH. No compiler change in
this task.

Builds on and uses the vocabulary of
[`record_field_cow_consuming_replacement_2026-09-16.md`](record_field_cow_consuming_replacement_2026-09-16.md),
which established the *field take*: `14501cb8` made the reuse pass rewrite the
retain in Perceus's owned-alias shape to `CowFieldTakeRetainPolicy(source,
field)` when a record update's replacement consumes the field it replaces, so
the backend empties the slot of a unique source instead of retaining. That
file's "Fix" table is the starting point here; the roadmap's R1 text predates
it. This task asks which shapes the field take does *not* reach.

## Answer

No. The roadmap's premise is out of date, and both candidate mechanisms named
in the task are wrong as stated.

* The old record's drop is **not** deferred to scope end. Perceus places
  `blorp_release(state)` inside the loop body, immediately before the
  reassignment.
* `RecordReuseExpr` **does** fire for `var state = { state | ... }` in a loop,
  and also for the hoisted variant.

The real gap is one step lower: the `CowFieldTakeRetainPolicy` selection in
`blorp/src/compiler/stage_09_core/reuse.brp` (landed in `14501cb8`) only
inspects the replacement expressions **inside** the record-update node. It
moves `state.items` out of a unique `state` when the append is written inline
in the update. When the same append is hoisted into a preceding binding, the
field read is a plain `blorp_retain`, the list has two owners across `append`,
and every iteration copies the whole vector. That is O(n^2).

So the shape the roadmap proposed as the minimal reproducer is the one shape
that is already fast, and the workaround applied in issue 149 — hoisting the
field into a local — is what made `dce.brp` quadratic.

The same one-line split decides the outcome through a function boundary too: a
consumed-parameter specialization with a fused update is linear, the same
specialization with a hoisted read is quadratic (shape 3 below).

## Allocation and time curves

Probe: `record State { items: List[Int], count: Int }` filled in a `while`
loop, measured with `memory.reset_mem_stats` / `get_mem_stats`. Four shapes:

| shape | loop body |
| --- | --- |
| `fused` | `state = { state \| items = state.items.append(i), count = state.count + 1 }` |
| `hoisted+rebuild` | `items = state.items.append(i)`; `next_count = state.count + 1`; `state = { items = items, count = next_count }` |
| `hoisted+update` | `items = state.items.append(i)`; `state = { state \| items = items, count = state.count + 1 }` |
| `alias (issue 149)` | `var items = state.items`; `items = items.append(i)`; `state = { items = items, count = state.count + 1 }` |

`total_allocations`:

| n | fused | hoisted+rebuild | hoisted+update | alias (149) |
| --- | --- | --- | --- | --- |
| 1 000 | 10 | 2 001 | 1 001 | 2 001 |
| 10 000 | 14 | 20 001 | 10 001 | 20 001 |
| 100 000 | 17 | 200 001 | 100 001 | 200 001 |

`fused` is `log2(n)`-ish: pure amortized vector doubling, no per-iteration
allocation at all. The other three are one (record copy + list copy) or one
(list copy) per iteration.

`MemStats.bytes_allocated` is a **live** figure, not cumulative, so it is
identical (1 048 656 at n = 100 000) for all four and does not show the copy.
Wall time does. Microseconds, same run:

| n | fused | hoisted+rebuild | hoisted+update | alias (149) |
| --- | --- | --- | --- | --- |
| 25 000 | 763 | 113 584 | 88 930 | 89 287 |
| 50 000 | 2 834 | 329 971 | 349 626 | 358 100 |
| 100 000 | 3 148 | 1 391 730 | 1 812 482 | 1 821 685 |

Extending `hoisted+rebuild` alone: 50 k = 0.76 s, 100 k = 2.44 s, 200 k = 10.9 s,
400 k = 47.0 s — 4.3x per doubling, i.e. quadratic. `fused` over the same range
is 2.7 ms / 5.7 ms / 8.8 ms / 20.0 ms, linear.

### Shape 4: a struct instead of a record

`struct Counter { total: Int, step: Int }` with `c = { c | total = c.total +
c.step }` allocates **zero** at every n measured (1 000, 10 000, 50 000,
100 000) and runs in 874 us at n = 50 000. A struct of primitives is a stack
value, so there is no record to keep alive and no ownership question. But
`struct` cannot replace the probe's record: the field that matters is a
`List`, which is a heap pointer, and `struct` is documented for "small stack
values with primitive fields". Shape 4 is a control, not an alternative.

## Core, after `reuse`

Reduced to the reference-counting operations (`--dump-core-after=reuse`):

```
##### fill_update          (fused)
    ('record(fresh alloc)',)                      -- the initializer, once
    ('record_reuse', 'source=state')
    ('dup', 'cow_field_take', 'state', 'items')   <-- field moved out

##### fill_lets            (hoisted+rebuild)
    ('record(fresh alloc)',)                      -- the initializer
    ('dup', 'arc', None, None)                    <-- plain retain, two owners
    ('record(fresh alloc)',)                      -- per iteration
    ('drop', 'state', 'arc')

##### fill_lets_update     (hoisted+update)
    ('record(fresh alloc)',)
    ('dup', 'arc', None, None)                    <-- plain retain, two owners
    ('record_reuse', 'source=state')              -- record reuse DOES fire

##### fill_alias_149
    ('record(fresh alloc)',)
    ('dup', 'arc', None, None)
    ('record(fresh alloc)',)
    ('drop', 'state', 'arc')
```

`fill_lets_update` is the decisive row: `RecordReuseExpr` is selected, so the
record itself is updated in place (1 allocation per iteration instead of 2),
and the list still copies. Record reuse and the field take are independent, and
only the field take is missing.

In the fused case the owned-alias read carries the take:

```json
{"kind":"dup","var":{"name":"$blorp$perceus$owned_result"},
 "retain_policy":"cow_field_take",
 "take_record":{"name":"state"},"take_field":"items"}
```

In every hoisted case the same node is `"retain_policy":"arc"` with no
`take_record`.

The drop placement is not the problem. In `fill_lets` the Core is

```
let __assign_state_0_0 = record{items = $items, count = $next_count}
seq  drop state (arc)
     assign state := $__assign_state_0_0
```

— inside the loop body, not at scope end.

## Generated C

Fused (`brp_20`), hot line:

```c
blorp_List* __blorp_internal_perceus_owned_result = state->items;
if (blorp_is_unique(state)) { state->items = NULL; }
else { blorp_retain(__blorp_internal_perceus_owned_result); }
...
({ blorp_List* __list_cap_ensure = (blorp_List*)__call_arg_3;
   long __list_cap_min_ensure = __call_arg_4;
   (__builtin_expect(__list_cap_ensure && blorp_is_unique(__list_cap_ensure)
                     && __list_cap_ensure->capacity >= __list_cap_min_ensure, 1)
    ? __list_cap_ensure
    : blorp_list_ensure_capacity(__list_cap_ensure, __list_cap_min_ensure)); });
...
State* __record_reuse_result_9 = __blorp_reuse_record_State(state, __record_field_7, __record_field_8);
state = __record_reuse_result_9;
```

`state->items = NULL` leaves the list at refcount 1, so
`blorp_is_unique(__list_cap_ensure)` is true and `append` takes the in-place
fast path. `__blorp_reuse_record_State` writes the fields back into the same
`State*`.

Hoisted+rebuild (`brp_21`), same region:

```c
blorp_List* __blorp_internal_perceus_owned_result = state->items;
blorp_retain(__blorp_internal_perceus_owned_result);     /* <-- two owners */
...
    ? __list_cap_ensure
    : blorp_list_ensure_capacity(__list_cap_ensure, __list_cap_min_ensure));
...
long next_count = (state->count + 1);
State* __assign_state_0_0 = State_make(items, next_count);
blorp_release(state);
State* __blorp_internal_perceus_owned_result = __assign_state_0_0;
blorp_retain(__blorp_internal_perceus_owned_result);
state = __blorp_internal_perceus_owned_result;
blorp_release(__assign_state_0_0);
```

`blorp_is_unique` is false on every iteration, so `blorp_list_ensure_capacity`
reallocates and memcpys the whole vector: n/2 elements copied per iteration.
The retain/release pair around `__assign_state_0_0` is also pure overhead.

## Shape 3: the record as a function parameter

`state = step(state, i)` in a loop, with the update moved into `step`. The
compiler builds a consumed-parameter specialization, visible in the Core dump
as `step_fused__consume_arg0`, and the field take fires inside it:

```
##### step_fused__consume_arg0      pure func step_fused(state: State, i: Int) -> State:
    ('record_reuse', 'src=state')       --     { state | items = state.items.append(i), count = state.count + 1 }
    ('dup', 'cow_field_take', 'state', 'items')

##### step_hoisted__consume_arg0    items = state.items.append(i)
    ('dup', 'arc', None, None)          -- then { state | items = items, count = state.count + 1 }
    ('dup', 'arc', None, None)
    ('drop', '__record_update_532', 'arc')
    ('record(alloc)',)
    ('drop', 'state', 'arc')
```

Allocations and microseconds for the loop `state = step(state, i)`:

| n | param, fused | param, hoisted | param, caller still reads |
| --- | --- | --- | --- |
| 1 000 | 10 / 80 us | 2 001 / 268 us | 2 001 / 265 us |
| 10 000 | 14 / 270 us | 20 001 / 14 688 us | 20 001 / 18 432 us |
| 50 000 | 16 / 1 918 us | 100 001 / 341 004 us | 100 001 / 369 497 us |

So consumed versus borrowed behaves correctly and the specialization is real:

* **Consumed + fused** is as fast as the inline fused form. The caller's
  `state` binding is dead at the call, ownership transfers, and the callee's
  `state` is unique. Generated C for `brp_oA` (`step_fused__consume_arg0`):

  ```c
  static State* brp_oA(State* state, long i) {
    blorp_List* __std_inline_self = ({
      blorp_List* __blorp_internal_perceus_owned_result = state->items;
      if (blorp_is_unique(state)) { state->items = NULL; }
      else { blorp_retain(__blorp_internal_perceus_owned_result); }
    __blorp_internal_perceus_owned_result; });
  ```

* **Consumed + hoisted** is quadratic: the specialization exists, `state` is
  unique at runtime, and the take still does not fire because the read is
  outside the update node. `brp_oB` and `brp_oE` show the bare
  `blorp_retain(__blorp_internal_perceus_owned_result);`. This is the same
  single gap as shapes 1 and 2, now inside the consume specialization.

* **Borrowed** (`next_state = step_fused(state, i)` with a second
  `step_borrowed(state, i)` afterwards, so the caller genuinely still holds
  the record) falls back to the retain and copies. That is correct, not a gap:
  two owners really exist. `brp_oE` opens with `blorp_retain(state);`, the
  borrow-to-consume adapter.

This refines the prior file's closing claim that "the dominant compiler shape
is `state = helper(state, x)` where the helper's `{ state | field =
state.field.append(x) }` sees a borrowed parameter while the caller still holds
the record", and that turning it into a win "needs consumed parameter
specialization, which is a separate lever". The specialization already exists
and already transfers ownership when the caller's binding is dead at the call —
`param, fused` is 16 allocations at n = 50 000, not 100 001. Where the field
take still falls back in the self-compile is therefore worth re-checking: at
least some of those 1 476 sites are hoisted reads, which this task's follow-up
would fix, rather than genuine sharing, which nothing can.

## Where `CowFieldTakeRetainPolicy` is chosen

`blorp/src/compiler/stage_09_core/reuse.brp`:

* `rewrite_post_perceus_expr` (~line 3160) rewrites only `RecordReuseExpr` and
  `RecordCowUpdateExpr` nodes, calling
* `take_self_consumed_record_fields` / `take_self_consumed_cow_fields`
  (~1915, ~1944), which count reads of the source var **across the update's own
  field values** with `var_touch_count` and, when a field is touched exactly
  once, call
* `take_field_alias` (~2020), which matches the Perceus owned-alias shape
  `BorrowLetExpr(temp, FieldExpr(VarExpr(source), field), DupExpr(temp, ArcRetainPolicy, ...))`
  and swaps `ArcRetainPolicy` for `CowFieldTakeRetainPolicy(source, field)`.
  It descends only through straight-line `Let`/`BorrowLet`/`Seq` spine
  positions, and `field_take_type_allowed` restricts it to single-heap-pointer
  fields (`List`, `Dict`, `Set`, `String`, `HeapRecordType`).

Nothing walks backwards from the update into the statements that precede it, so
a hoisted read is never a candidate.

## Scoped follow-up task

**Title.** Take a self-consumed record field that was read into a preceding
binding.

**File.** `blorp/src/compiler/stage_09_core/reuse.brp` only. No other compiler
file changes; `emit.brp` already lowers `CowFieldTakeRetainPolicy`, and
`ir.brp` already defines and round-trips it.

**Function and change shape.** `rewrite_post_perceus_expr` currently rewrites a
`RecordReuseExpr` / `RecordCowUpdateExpr` in isolation. Add a spine rewrite one
level up: at a `LetExpr(binding, rhs, body)` (and the `BorrowLet` / `Seq`
equivalents) whose `body` reaches a `RecordReuseExpr` or `RecordCowUpdateExpr`
with `source = VarExpr(s)` through straight-line positions only, treat `rhs` as
an additional candidate for `take_field_alias(s, field, rhs)` for each field the
update replaces, subject to exactly today's conditions plus the ones the
hoisting adds:

1. The update's source is the same bare `VarExpr(s)` and `s` is consumed there
   (already checked by the existing reuse selection).
2. Summing `var_touch_count(s, field, ...)` over the hoisted `rhs`, every
   statement between it and the update, and every replacement value of the
   update gives exactly 1 — so the emptied slot cannot be observed. Reusing
   `var_touch_count` unchanged keeps lambdas, closures and reassignments of `s`
   disqualifying at 2.
3. The intervening statements are on the straight-line spine: no `While`, `If`,
   `Match`, or lambda body between the hoisted read and the update. Reuse the
   descent discipline already documented on `take_field_alias`.
4. `field_take_type_allowed` on the field type, unchanged.
5. For `RecordCowUpdateExpr`, `is_arc_release_policy(field.release_policy)`,
   unchanged.

This is the same rule the existing code applies, with the search window widened
from "the update's own field values" to "the straight-line block ending in the
update". Condition 2 is what makes it sound: if `s.items` is read once in total,
nulling the slot is invisible, because the update writes the slot back before
`s` is read again.

The secondary gap — `hoisted+rebuild` builds a fresh `State` instead of reusing
`state` because the constructed record does not mention `state` — is worth one
extra allocation per iteration but is not the quadratic term. Leave it out of
this task; it is a reuse-selection question, not an ownership one.

**Fixture that proves it.** `blorp/test/runtime/memory/test_record_update_field_take_ownership.brp`
(committed by this task). It passes today by asserting the current numbers. The
follow-up flips two expectations:

* `test_hoisted_append_then_rebuild_copies_every_iteration` —
  `total_allocations >= 2 * ROUNDS` becomes `total_allocations <= ROUNDS + GROWTH_ALLOCATION_CEILING`
  (the record copy remains, the list copy goes).
* `test_hoisted_append_then_update_reuses_the_record_but_copies_the_list` —
  `total_allocations >= ROUNDS` becomes `total_allocations <= GROWTH_ALLOCATION_CEILING`.

`test_fused_record_update_grows_the_field_in_place` must keep passing
unchanged; it guards the behavior `14501cb8` added.

Add to the same file, with the follow-up, a parameter case: a helper
`pure func step(state: State, i: Int) -> State` whose body hoists the append,
called as `state = step(state, i)` in a loop. It goes through the consumed
parameter specialization and is quadratic today; the rewrite is per-function
Core so it should fix the specialization for free, and the test proves it.
Also keep a genuinely borrowed case (the caller reads `state` again after the
call) asserting the copy still happens — that is the fallback the take must
not break.

Compiler-level test: revert the six-locals workaround in
`blorp/src/compiler/stage_09_core/dce.brp` back to the record-threaded form and
confirm self-compile allocations and instructions do not regress, using
`benchmarks/self_compile_measure` against the r3 baselines. Also run
`scripts/test compiler-core-sanitize leak` — this change nulls a field slot, so
a missed touch is a use-after-free, not a slowdown.

## Payoff estimate: record-threaded state in the compiler

Record updates are pervasive: 1 563 `{ x | ... }` expressions across
`blorp/src/compiler`, concentrated in `stage_09_core/perceus.brp` (252),
`traverse.brp` (82), `stage_08_core_lower/flatten.brp` (75),
`stage_09_core/std_inline.brp` (72), `tuple_sroa.brp` (70), `closure.brp` (67),
`prepare.brp` (60), `fairness.brp` (53), `resource_management.brp` (52),
`stage_06_typecheck/decl.brp` (51), `stage_09_core/ssa.brp` (44),
`stage_06_typecheck/state.brp` (42).

Most of those are the fused form and already take the fast path. The ones this
follow-up would newly fix are the sites that read a collection field into a
local first and rebuild the owning record within a dozen lines: a heuristic
scan finds about 66, led by `stage_06_typecheck/type_system/env.brp` (9),
`modules/module_binding.brp` (6), `stage_09_core/match_lowering.brp` (5),
`synth_context.brp` (5), `stage_02_lex/lexer.brp` (4),
`headers/callable_headers.brp` (4), and two in `stage_09_core/dce.brp` — the
issue 149 site itself. Every one of those inside a loop over declarations,
tokens or Core nodes is a latent quadratic.

The larger payoff is not the 66 sites but the maintainability one the roadmap
names: once a hoisted read is as fast as a fused one, record-threaded state
(`LexerState`, `PerceusEnv`, the closure and SSA states, DCE facts) stops
having a performance cliff that pushes workers toward loose locals, and the
issue 149 workaround can be reverted.

## Reproducing

Probe sources used for this finding are not committed; the committed
characterization test covers the same three shapes at n = 1 000. To rebuild the
curves, copy the shapes from the table above into a scratch program, add a
`for n in [1000, 10000, 100000]` driver around `reset_mem_stats()` /
`get_mem_stats()`, and run `bin/blorp run`. For the Core and C:

```bash
bin/blorp compile --no-format --dump-core-after=reuse \
  --dump-core-file=/tmp/core_reuse.txt -o /tmp/out.c /tmp/probe.brp
```

The dump is one JSON object on a line; filter `decls` by function name.
