# Compiler-source loops

This is a local implementation design on the unaccepted functional overlay
`4bf351198795fa24659cb1fbda731b9747d3f53c6a506ea8625c9778db60aae1`
applied to `9b5348a6bcdb23b2fce58c0bae807e06dbeeeb36`. It grants no
acceptance, baseline roll, CPU slot, merge or push. Historical cost failures and
original baselines remain authoritative.

**Integration status.** Common source while/for, managed headers, lexical loop
transfers and the ownership products below are implemented in the combined
candidate; integrated acceptance remains pending. The old prechange outcomes,
product proposals and demand census below retain their historical context.
Ordinary allocation-cap misses are deferred debt during self-compilation work
unless egregious; preserve their counts and instruction history. Functional
behavior, ownership, leaks, sanitizers and exact diagnostics take priority. This
records no resource PASS and changes no ceiling.

## First witness and demand

`test/e2e/fixtures/source_loops/list_sum.brp` must return 6 through its normal
main. Its checker witness lives in `test/unit/test_check/test_source_loops.brp`.
The prechange outcome is expected to be the exact unsupported-for diagnostic;
no compiled RED has run yet. Root owns serialized compiled CPU slots.

The initial current-main textual census finds 421 for statements, including
six integer ranges, 89 while statements, 307 break and one continue. The
collection expressions use lists, including list literals, concat/append,
IntMaps.values and note_lines. No String iteration has been found; declaration
type confirmation and the overlay census are still pending. String iteration
is excluded unless an actual compiler source demands it. The only explicit
continue is in check/receiver_clashes. Existing parser rules already isolate
lambda entry and reject loop control in value-position if/match operands.

The exact functional overlay census is 456 for (449 collection expressions,
7 ranges), 90 while, 322 break and one continue, retained under
`build/source-loops/INVENTORY.json`. Counts above describe a distinct current-main
source role and are not interchangeable. Carried source demand includes managed
records: `src/utils/int_map.brp:88` reassigns `rebuilt: IntMap[V]`, whose fields
contain Lists. Therefore a String/List-only H whitelist is insufficient.
Existing sealed ownership layouts must drive H generically for already
supported concrete records/unions/collections; this does not admit managed TCO.

## Facts and ownership

| Fact | Producer and lifetime | Consumers |
| --- | --- | --- |
| List element type or Int range endpoints | Check, sealed checked for product | Spec translates it; Lower does no name/type resolution |
| Nearest unlabelled loop control | Check, lexical checked statement containment | Spec preserves it; lambda entry clears outer scope |
| Enclosing carried BindingIds, excluding iteration locals | Check, ordered once with existing carried_bindings | Spec translates binding types; Lower constructs H and P |
| Concrete layouts and ownership | Spec, existing sealed layouts | Own and independent Verify consume them |
| Runtime loop target | Lower, existing primary result ValueId wrapped as LoopTarget | Own preserves it; Verify checks active scope; Emit projects labels |
| Entry H obligations and every outgoing occurrence | Own, explicit acquisitions and transfer batches | Verify consumes each obligation once; Emit never invents ARC |
| PRE owner snapshot | Own/Verify, lexical loop scope | Every Break/Recur must preserve captured PRE; nested scope does not discharge it |

One runtime Loop serves while, for and existing scalar tail recursion. For
evaluates its iterable/endpoints once, outside that Loop. A List iteration
borrows from the frozen iterable, projects each item only on its present edge,
and advances its cursor on both normal and explicit continue edges. Range
iteration is ascending and end-exclusive, including empty/reversed ranges;
the upper bound is captured once. Body-local mutable values do not become
outer H. Each nested Loop publishes its carried P back into the enclosing
binding map before outer execution resumes.

The checked for product is explicit about its iteration operation:

```blorp
fixed union CheckedIteration:
    ListIteration(CheckedExpr, TypeRef, DesignatedOption[VariantId])
    AscendingIntRange(CheckedExpr, CheckedExpr, DesignatedBoolean[VariantId])
fixed record CheckedFor {
    iteration: CheckedIteration,
    item: Option[BindingId],
    carried: List[BindingId],
    body: List[CheckedStatement],
    span: Span
}
```

Check validates List element/item compatibility or both Int endpoints once;
it receives the existing foundation's designated Option alongside Bool.
`item=None` means the source's explicit discard binder: four actual compiler
loops use `for _ in ...`. It is not an absent required fact. Spec's
statement_types requests `AppliedUnionType(variant_owner(option.some),[element])`
and uses the existing translate_option to publish concrete constructors. Lower
uses the existing ListGet intrinsic and Some payload projection/None Break;
there is no ListLength scan, unchecked indexing helper, signature search or
String iterator. Range uses existing IntLessThan and IntAdd. This typed
operation distinguishes source ranges before ordinary expression checking,
where stand-alone range values remain rejected.

Managed entry acquires one internal H obligation per occurrence, including
duplicate aliases and borrowed initial roots. Each edge acquires all outgoing
occurrences before retiring old H and iteration-local owners. Borrowed PRE
owners survive every inner and outer edge. List elements borrowed from a
managed iterable must remain protected until transferred or their last use.

## Product seam for early peer review

The pre-implementation `LoopArm { label, steps, exit }` permitted only flat terminal matches.
Change it to `{ label, body: LoopBlock }`, with the same recursive change in
Own. This alone cannot express a linear-size sequence of conditionals that
may exit early: duplicating the suffix into every normal arm can grow output
exponentially. Ordinary joins must remain the branch/continuation authority.

The terminal-product design implemented in the integration candidate:

```blorp
opaque type LoopTarget = ValueId
fixed union JoinExit:
    Yield(JoinOutputs)
    TransferLoop(LoopTarget, LoopTail)
fixed record JoinArm {
    id: MatchArmId,
    inputs: List[ValueParameter],
    steps: List[LoweredStep],
    exit: JoinExit
}
fixed record LoopArm {
    id: MatchArmId,
    inputs: List[ValueParameter],
    body: LoopBlock
}
```

`JoinOutputs` contains the existing value/carried pair. An abrupt edge never
publishes the join's continuation outputs; only Yield arms reach that
continuation. TransferLoop retains the existing recursive LoopTail, so a mixed outer Join
can contain a fully abrupt nested selection without duplicating a suffix.
Lower resolves source lexical transfer once to the enclosing
LoopTarget. A nested Loop starts a fresh target. Verify rejects absent or
foreign targets, missing/duplicate transfer owners, wrong arity/type and live
old H/locals. Emit maps resolved targets to C labels, so arbitrarily nested
switches cannot intercept break. No origin flags, second loop backend or
String-specific emitter are introduced. Labels derive from issued ValueIds,
not source positions or spelling.

The pattern worker owns `LoweredSelection`, `MatchArmId`, decision selection
and canonical arm input arguments. Common Join and terminal LoopMatch both
consume that same selector/arm-entry contract, including the annotated
CheckedMatch/ConcreteMatch TCO route; there is no second pattern emitter.
SelectionEdge admits only sealed projection/suffix definitions, never arbitrary
user calls, joins or loops. Entry edges acquire independent projected
occurrences or transfer newly owned suffixes without consuming/dropping/moving
an enclosing owner. Every path to a shared arm therefore has the identical
enclosing live-owner snapshot plus canonical arm-input ownership.

`inputs` above is its shared seam: empty for present Bool/simple-variant arms,
typed canonical parameters for selected captures. Its Accept transfers supply
those parameters once before the ordinary arm steps. Arm entry does not
change Yield versus loop transfer semantics. There is one common Join, not a
parallel PatternJoin or LoopJoin. The illustrative loops below use empty arm
inputs except the ordinary projected List item binder.

### Concrete early-break path

The following source uses only the already accepted condition and concrete
String builtins; add/stop declarations are omitted here for clarity.

```blorp
pure func run(seed: String, limit: Int) -> String:
    var text: String = seed
    var cursor: Int = 0
    while less_than(cursor, limit):
        local = add(text, "x")
        if stop(cursor):
            text = local
            break
        text = add(local, "y")
        cursor = increment(cursor)
    text
```

Check publishes the existing statement-if CheckedJoin, with its True arm
containing `ReassignBinding(text, local)` and a typed `BreakSourceLoop(span)`
statement. The False arm remains the canonical Void value. Both branches
thread complete bindings/LambdaRows, and the enclosing while's ordered H
identities are `[text, cursor]`. Lower binds those IDs to `Htext/Hcursor`,
publishes its target `LoopTarget(Pvoid.id)`, and resolves Break at that point:

```text
Loop target=T, H=[Htext<-seed, Hcursor<-0], P=[Pvoid,Ptext,Pcursor]
  condition = less_than(Hcursor,limit)
  LoopMatch condition
    False: Break(Void,Htext,Hcursor)
    True:
      local = add(Htext,"x")
      Join Jvoid/Jtext (stop(Hcursor))
        True: ExitLoop(T,Break(Void,local,Hcursor))
        False: Yield(Void,Htext)
      updated = add(local,"y")
      next = increment(Hcursor)
      Recur(updated,next)
```

There is no Jvoid/Jtext value assigned or consumed on the abrupt arm. Its
outgoing Ptext acquisition uses local, not the normal continuation's Htext.
The False arm publishes Jtext normally; the remaining source statements are
emitted once after the join. Lower's statement/block result explicitly
distinguishes Continuing from Abrupt. If every arm is Abrupt, the branch becomes
a terminal recursive LoopMatch, publishes no Join outputs, and lowers no
unreachable suffix. Checking may still diagnose unreachable written source;
Check owns lexical and type legality; Lower normalizes typed Concrete statement
sequences once into private prepared blocks and selections. Their continuing
or terminal products determine whether Lower reserves outputs. Parse rejects
source control in ValueInLoop operands, including scrutinees and initializers;
nested loop bodies and lambda creation do not export their transfers. Do not
infer completion from an empty carrier list, Void type or source spelling.

Own's True edge acquires a new obligation for local first, then retires local,
Htext and any still-live intervening branch/iteration owners, and publishes
the P transfer. Hcursor/Void need no owner. The borrowed seed and every actual
live PRE obligation survive. The normal False edge acquires Jtext and retires
only its arm locals; it leaves Htext/local live for the continuation according
to normal last-use scheduling. The final Recur acquires updated before retiring
old H and the remaining locals. If two outgoing slots refer to local, both
acquisitions precede its one retirement.

The existing pending-arm insertion delays arm construction until the parent
interval is sealed. Therefore an abrupt arm needs the exact live enclosing
obligations at the join occurrence, not all historical source owners or the
parent's final state. Extend the existing lexical insertion context with its
drop schedule/position snapshot and active loop boundary; do not rescan a body
or treat already-dropped owners as live. This is a required design seam for
the review and is implemented in integration, with acceptance still pending.
Verify receives its own PRE snapshot and
checks branch operations/edge consumption independently of that insertion
context. It must reject a missing old-header drop, duplicate local drop,
unavailable destination, or captured PRE discharge.

The C projection is direct control flow over sealed targets:

```c
/* explicit entry acquisitions; H storage; P declarations */
loop_T_head: ;
/* immutable H snapshots and condition operations */
switch (condition.tag) {
case False: /* false edge acquisitions/cleanup/P batch */ goto loop_T_exit;
case True:
    /* local and stop evaluation */
    switch (stop.tag) {
    case True: /* acquire local; cleanup; P batch */ goto loop_T_exit;
    case False: /* ordinary Yield assigns J outputs */ break;
    }
    /* one copy of updated/next; acquire outputs; retire H/locals */
    /* assign all H storage from captured outgoing values */
    goto loop_T_head;
}
loop_T_exit: ;
/* ordinary continuation receives P */
```

Labels contain the projection of an issued target identity; their spelling is
never interpreted. The illustrative labels above stand for existing ValueId
projection. Gotos replace the present one-switch break/continue trick for
every common Loop, including scalar TCO; no origin-based emission route.

### Nested-loop continue path

```blorp
for outer in [1, 2]:
    for inner in [True, False]:
        if inner:
            continue
        total = add(total, outer)
    total = add(total, 10)
```

Check's inner statement receives the inner loop scope; lambda resolution
instead starts OutsideSourceLoop and restores its parent on return. Lower's
outer Loop target is Touter and inner Loop target is Tinner. The True inner
join edge becomes `ExitLoop(Tinner,Recur(next_inner_cursor,total))`: advancing
the for cursor is part of the for backedge, including explicit continue.
Touter's cursor and owners are inner PRE, so they are preserved. The False
arm yields and reaches the one copy of the inner-body addition. The inner
natural exit transfers its current total into Pinner, then the outer body
adds 10 and eventually recurs Touter. Emit jumps to Tinner's header label;
neither an enclosing switch nor Touter can intercept it. Verify rejects a raw
Touter reference from an unlabelled inner control product, or a target from a
sibling loop, rather than silently transferring to a different header batch.

Owned H uses explicit ownership rather than the old unmanaged
`List[LoopHeader]`:

```blorp
fixed record OwnedLoopHeader {
    parameter: OwnedJoinParameter,
    initial: ReturnTransfer
}
fixed record OwnedLoop {
    entry_acquisitions: List[OwnerAcquisition],
    headers: List[OwnedLoopHeader],
    result: OwnedJoinParameter,
    carried: List[OwnedJoinParameter],
    body: OwnedLoopBlock
}
```

Own now names the former private `ChildAcquisition { owner, borrow }`
`OwnerAcquisition`, since the same acquisition payload serves aggregate
children and loop entry. Each header's parameter span supplies the acquisition diagnostic
anchor; no second type/layout authority is stored. Entry acquisitions and header owners
are allocated in the loop's private owner interval after the parent interval
closes; outputs P stay in the parent interval. PRE is captured before any
entry acquisition. Verify checks every explicit acquisition once, consumes
the initial transfer batch, and only then introduces fresh H ownership.
Each iteration's aliases bind those same static H OwnerIds to the new incoming
obligations. The entry acquisitions execute outside the loop's header label,
never on a backedge. Outgoing edges consume distinct acquisition obligations
after retiring old H/locals. Emit consumes these operations and aliases; it
never synthesizes retains from the concrete type.

### Early independent review

The first read-only local code-reviewer verdict was changes requested, with
two blockers and two should-fixes. The managed entry product above addresses
the first blocker. The exact-live lexical obligation snapshot and independent
edge-mode verification described in the concrete example address the second.
The Continuing/Abrupt completion rule addresses all-abrupt branches; Verify
requires target equality with the nearest active loop, rather than mere active
membership. The shared product and completion seams now have independent architecture
approval. The active broad-loop checkout contains the producer/consumer
implementation on the reviewed but unaccepted flat-selection dependency
`bd43dcc791bd467de610dfef20f2994be9b7195bb77c3678111ba27af36895a8`.
Focused compiled behavior, native ownership, mutation and matched cost proof
remain required; physical source changes and static review do not satisfy them.

## Complete affected walker inventory

Check: resolve_statement, resolve_while, resolve_statement_block, resolve_if,
resolve_join_arms; check/model append_statement_calls; check/recursion
statement_values; source-loop errors and rendering. Preserve global LambdaRows
threading and fresh lambda loop scope.

Spec: statement_types, translate_statements and admit_scalar_statements. Remove
the obsolete source-loop NoOwnership admission family; preserve generic
translation/request order, match translation and existing scalar-TCO admission.

Lower: step_reads/span/value_count, value_span, lower_statement/statements,
prepare_while, complete_while, complete_joins, lower_join_arm, lower_body,
lower_function. All fresh value intervals and published read summaries must
include branch exits and recursive loop blocks.

Own: block_uses, insert_steps, complete_joins, insert_join_arm, leave_join,
leave_loop, insert_loop_edge, insert_loop. Explicit edge acquisitions must all
precede local/header retirement; no move fast path for common loop edges.

Verify: verify_operations, verify_joins, verify_join_transfers,
verify_loop_header, verify_loop_exit, verify_loop_match, verify_loop,
complete_loop_owners, verify_entry. Independent malformed products must test
targets, lexical PRE protection and both initial/backedge transfer batches.

Emit: owner_types, append_ownership_operation(s), append_cases, append_join,
append_loop_exit/match/loop, append_block/function_blocks, program_inventory.
Inventory must recursively visit headers and every operation exactly once.

## Forecast and narrow gates

This new full-source slice does not fit the historical first-while/String-only
750-addition forecast. Initial complete forecast is 1,500-2,200 production
additions / +1,200-1,800 net, 1,800-3,000 test additions / +1,400-2,400 net,
and 3-5 fixtures / 100-180 lines. Reforecast the concrete reviewed model before
implementation; these are estimates, not permission to exceed an older cap.
Proposed shared-input ceilings are +5% allocation/instruction target and +10%
hard limit, with numerical new-fixture absolutes frozen before measuring.
Preserve all original failure reports and independently measure against the
Root-named baseline. Until self-compilation works, owned inputs are proxies.

The reviewed implementation's offline count against the original functional
tree plus the literal nine-source-file flat-selection postimages is 1,692
production additions / 708 deletions / +984 net. Against the matching 56 test
postimages, unit tests are 3,570 additions / 726 deletions / +2,844 net; e2e
owners and fixtures are 286 additions / 10 deletions / +276 net. These
differences include the later flat-selection host-layout and first-error
corrections, rather than claiming an isolated loop-only cost. The increased
test forecast includes migration of existing phase observers and independent
malformed ownership/target cases. Source counts stay within the forecast;
these line counts establish no measured runtime or allocation result. The raw
per-source accounting is retained in the active checkout at
`build/source-loops/line-counts-offline01.json`.

First run the new checker suite and existing Check15/Spec3 while owners using
retained host498 and host-std91, exact private environment with only owned PWD
substituted. Then phase-test List/range facts, H/P ordering, nested lexical
targets, edge cleanup and independent malformed IR. Native fixtures cover
0/1/many iterations, condition n+1 evaluation, List/range sum, nested control,
managed List/String growth, duplicate aliases, borrowed roots and natural/early
exit. Require deliberate wrong-state/break/ownership faults, exact outputs,
zero leaks and sanitizers. Preserve all TCO/ABI owners. Finish with actual
compiler-source inventory, self-compilation and fixpoint, or name the exact
remaining source frontier without claiming completion.

Root arranges early peer validation and serial CPU slots. Implementation stays
in this isolated worktree; no independent publication or planning-only commit.
