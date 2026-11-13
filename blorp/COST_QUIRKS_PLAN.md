# Cost quirks

Plan revision 1, 2026-11-12, written against origin/main `525b653c2` and
rebased onto `476ceef23` on 2026-11-13; the measurements below were taken on
`525b653c2`. The
cost-quirks pilot of 2026-11-12 found these; its probes, attribution tables
and raw samples are in the main checkout's ignored
`build/pilots/2026-11-12/cost-quirks/`.

**Status:** approved by Keith on 2026-11-12 (decisions below). Four landings,
stacked: L1, L2, L3 and Q2. No seed rotation is part of this plan; the
compiler's own source benefits from L1 and L2 once a later seed carries them.

## Problem

Two programs that mean the same thing could cost very differently, and the
compiler's source bent to avoid the expensive forms. Paired probes (cheap form
against expensive form, strict leak check and copy counts) sorted the
documented quirks:

| Quirk | Expensive form | Finding |
|---|---|---|
| Q1 | a `?=` between a `var` List and its appends | Stale: same cost today. L3 removes the notes. |
| Q3 | a path of a record function that returns a helper's result | Stale: same cost today. L3. |
| Q11 | `"${output}<${label}>;"` with a borrowed hole | 2,006 allocations against 6 for the `+` chain. L1. |
| Q9 | a loop that rebuilds a record of Lists | 6,001 allocations and 4,000 List copies against 2. L2. |
| Q2 | an accumulator passed to a fallible call in a `failure` + `break` loop | 3,000 copies, 19.7 MB, against none when the loop carries a `Result`. Q2. |
| Q4 | a lambda bound to a local before it is passed | One allocation per call. Not changed (decision 3). |
| Q5, Q6 | a record or tuple with a managed field, built and read at once | One allocation each. Records design pilot (decision 4). |
| Q7, Q16 | reading a value after updating it; growing a List element in place | Inherent: the old value is still read. The README rule covers them. |

## Keith's decisions, 2026-11-12

1. L1 and L2: yes.
2. Q2: `?=` stays out of loops. Emit's failure-flag loops become loops that
   carry a `Result`.
3. Q4, the named lambda: change it only if that saves a lot and is simple. It
   does not qualify: one site in `src`, none in the standard library or the
   benchmarks. Not in scope.
4. Q5 and Q6, records and tuples by value: yes in principle, in a separate
   design pilot (below).
5. The README states the cost rule.

## Landings

1. **L1, interpolation as one left-nested chain** (`check`). The checker
   joined interpolation parts as a balanced tree, so every right subtree began
   a new String from its first part and copied it when that part was borrowed
   or a literal. Parts now append in written order to the String the earlier
   parts built, as a written `+` sum does; specialize and lower already walk
   such chains in a loop.
2. **L2, a loop iteration ends the obligations it inherits at their last
   read** (`own`). An owner a loop arm inherits from an enclosing block could
   be moved at its last read in the iteration but was otherwise dropped only
   at the back edge, so a record rebuilt each iteration stayed alive while its
   fields were updated, and every update copied. An owner the iteration
   reads now ends at its last read there, as a yielding join arm's entering
   owner does. One it inherits but never reads still ends at the back edge,
   where a join arm would drop it on entry (see Follow-ups). The README states
   the cost rule in its Own section.
3. **L3, stale notes.** Comments that described copies of the retired host
   compiler.
4. **Q2, loops that carry a `Result`** (`emit`). Each loop that passed its
   accumulator to a fallible call kept an `output` and a `failure` flag; on
   the failure path the old accumulator is the loop's result, so every call
   copied it. One `Result` replaces each pair.

## Records by value

Moved from `NEXT.md` on 2026-11-12. A plain record returned by value is
heap-allocated even when the caller destructures it at once. The lexer's
`SkippedLines` costs one allocation per code line, 37,160 in the self-compile
(`LSP_PLAN.md`, landing 2's measurement). Records are 56.5% of the
self-compile's allocations (7.98 M of 14.13 M at `203541220`). Keith approved
values by representation in principle; the records design pilot owns it.

## Follow-ups

Found while landing; none is in this stack.

- **Drop unread inherited owners on entry.** An owner a loop iteration
  inherits but never reads lasts until its back edge, where a yielding join
  arm drops one on entry (`own.brp`, `loop_consumption_uses` against
  `entering_discharges`). In
  `while bag.items.length() < n: bag = { bag | items = bag.items.append(x) }`
  the condition's projection is such an owner, so each append still copies.
  `owned_parameters/loop_condition_projection` records today's count.
- **`loop_uses` carries only held header rows,** and lowering never produces
  a held header (`lower.brp:2190`, `2393`). Remove the parameter or give it a
  producer.
- **A `while` condition's owners last until each arm's exit.** A loop match's
  prefix keeps every owner to its arms, so an update inside the condition,
  such as `[7].append(total)`, copies instead of consuming its operand.
- **Two emit loops still keep a failure flag:**
  - `append_record_ownership`'s field loop, which passes its accumulator to
    `append_storage_operation`;
  - `append_loop`'s header loop, which carries two accumulators under one
    flag, so one `Result` would need a record or tuple.

## Measurements

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0. Other sessions ran gates
throughout. Allocations come from one strict run of a
`-DBLORP_MEMORY_DIAGNOSTICS=1` binary and are deterministic; instructions are
the median of alternating `/usr/bin/time -l` runs.

`blorp/scripts/self-compile-cost` builds both sides from the pinned seed, so
for L1 and L2 it measures only what the change costs the compiler's passes.
Their benefit to the compiler's own code needs stage-2 compilers: each side's
seed-built compiler compiles its own source at `-O2`, normally and with memory
diagnostics, and both stage-2 compilers then compile the branch base's source.

### L1 (2026-11-12)

Base `525b653c2`, candidate `cost/l1-interpolation-chain`. Stage-2 compilers
compiled the base's source.

| | Base | L1 | Change |
|---|---:|---:|---:|
| Allocations (strict) | 14,130,149 | 13,932,953 | −197,196 (−1.40%) |
| Instructions (median of 5) | 12,377,762,686 | 12,262,323,752 | −0.93% |

- Instruction samples: base 12,377,762,686, 12,398,258,431, 12,385,795,311,
  12,356,183,952 and 12,370,513,772; L1 12,262,323,752, 12,265,225,318,
  12,281,552,516, 12,259,466,492 and 12,236,944,368, alternating sides.
- Stage-1 compilers (SHA-256): base `9f616f54…`, L1 `b2083b29…`. Stage-2 C:
  base `380ae66f…`, L1 `a1963871…`; the L1 stage-2 compiler reproduces its
  own C. Their C for the base's source: base `380ae66f…` (its own stage-2 C),
  L1 `46db21d4…`.
- The interpolation fixtures with 8, 32 and 128 holes allocate 5, 17 and 65
  times at base and twice each with L1. L1 lowers 25 exact runtime counts in
  all, those three included, raises none and raises no compile ceiling.
- A fixture with two 2,000-hole interpolations, one of them a record update's
  replacement that lowering scans for its base's reads, compiles at default C
  limits and allocates 6 times. Lowering's `collect_base_reads` recurses once
  per link of such a chain, and handles the 2,000 links.
- The pilot's attribution of the self-compile at `203541220`: String update
  copies fall from 20.4 MB to 10.3 MB. The largest site,
  `emit.append_selection_body` (8.65 MB), no longer copies.

### L2 (2026-11-12)

Base `cost/l1-interpolation-chain`, candidate `cost/l2-loop-last-read`.

- **Tests.**
  - `test_own`: "an inherited record drops before its field grows", which
    asserts that the record header's drop precedes the update, fails on L1
    and passes with L2.
  - `test_own` guards that pass on L1 too: "an inherited owner an update
    takes is not dropped" and "an inherited owner the iteration never reads
    retires at its edge".
  - `test_verify` guards, which pass on L1 too because verify is unchanged:
    "a back edge cannot retire an owner its iteration dropped", and "a back
    edge cannot discharge an owner made before its loop", which pins the rule
    (`verify.brp`, "loop edge discharges a captured owner") that keeps L2 from
    dropping an owner made before the loop.
- **Probes.** Seven fixtures under `owned_parameters/loop_*`. Each runs under
  strict accounting and ASan and UBSan, and prints the same output under L1
  and L2, which is the base compiler's output too.

  | Fixture | L1 | L2 |
  |---|---:|---:|
  | `loop_record` | 304 | 106 |
  | `loop_reads_every_iteration` | 18 | 18 |
  | `loop_reads_after_loop` | 9 | 9 |
  | `loop_one_branch` | 18 | 18 |
  | `loop_nested` | 25 | 22 |
  | `loop_exits` | 39 | 34 |
  | `loop_projection` | 35 | 33 |

  These are runtime allocations. Their compile ceilings are the L2 test
  compiler's measured cost on `476ceef23` plus 15%.
  `loop_condition_projection` (202 allocations) records the copy L2 leaves:
  see "Drop unread inherited owners on entry" under Follow-ups.
- **Lowered counts.** `record/update/field_accumulator` 57 to 53 and
  `source_loops/managed_headers` 27 to 25. No count rose.
- **Stage-2 self-compile** on L1's source: allocations 13,930,448 to
  13,929,785 (−663), median instructions 12,254,329,814 to 12,247,222,930
  (−0.06%, within noise). The compiler's own source avoids rebuilding a record
  in a loop, so L2 serves user code. Samples: L1 12,268,706,372,
  12,250,684,522, 12,265,757,681, 12,254,329,814 and 12,252,504,057; L2
  12,256,785,788, 12,247,222,930, 12,234,189,345, 12,257,489,950 and
  12,244,823,714. The L2 stage-2 compiler reproduces its own C (`94bd3323…`).

### Q2 (2026-11-13)

Base `cost/l3-stale-notes`, candidate `cost/q2-result-loops`. The rewritten
loops:
- `c_parameters`;
- `append_value_field_actions`;
- `append_union_action`;
- `append_boxed_union_release`;
- the owner-alias loop of `append_input_owners`, which `append_join` now
  calls for its outputs instead of repeating it.

`blorp/scripts/self-compile-cost` was run with five rounds. Both sides are
seed-built, which here is the point: the change is to the compiler's own
loops.

| | Base | Q2 | Change |
|---|---:|---:|---:|
| Fixed input allocations | 14,125,970 | 14,110,365 | −15,605 (−0.11%) |
| Fixed input instructions, median of 5 | 12,357,727,702 | 12,339,989,924 | −0.14% |
| Own source allocations | 14,125,970 | 14,115,792 | −0.07% |
| Own source instructions, median of 5 | 12,346,174,608 | 12,322,892,348 | −0.19% |

The fixed-input C is identical (`8a34d0bbce643bff`).

The pilot estimated about 99,500 allocations from the site's allocation
count. Most of those allocations are the first allocation of a String that
starts from `""`, which no loop shape removes. Two loops of the same pattern
remain (see Follow-ups).
