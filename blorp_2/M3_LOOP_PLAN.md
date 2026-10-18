# M3: common loops, then managed String while

## Status, dependencies and review boundary

The next checkpoint is an independently working ordinary-tail preparation,
reviewed by root and two independent compiler experts on 2026-10-18. Commit this
amendment separately after review, before its bounded implementation dispatch.
The broader common-loop checkout is currently unavailable after interruption;
root and the primary session are checking recovery. Preserve any recovered
source and ignored evidence. This checkpoint does not approve resuming that
draft or establish that it fits the whole cap.
The original approved plan is preserved in Git; all numerical ceilings below
remain unchanged.

The preceding plan's approved ceilings and baseline-policy restrictions remain
binding. Commit this documentation separately; implementation needs its own
bounded dispatch. No cost setup, baseline freeze or sampling is authorized while
SOURCE policy and the accepted measurement baseline remain unresolved.

M2 carried joins are accepted at
`7acd6df25c4fe62c726614e8e9ea970071c35f73`. The scalar WIP began at unary commit
`db8abb15af4250eba1ad4c6d3efc8171cf35adaf` with historical prospective patch
SHA-256 `b67726f0943af21afbf4dfdb71462a241c315c5b15f9c5d25e9133a7e6622778`.
Its pinned source/test/library trees were verified identical to accepted M2;
these anchors refer to those accepted bytes. Preserve that WIP/index and all
campaign pins. Review composition against accepted M2 before final gates and
publication, retaining accepted documentation; do not destructively rebase the
old stack or implicitly roll the host, standard library or measurement epoch.

Scalar preparation does not depend on the Boolean feature. Managed while
reuses its accepted designated-Bool route (root review identifier `800b`), or
requires review of a bounded port of that same route if it has not landed.
Do not create a parallel Bool channel. The unresolved SOURCE baseline policy
does not block this plan or static consumer inventory; cost gates stay pending.

## Immediate checkpoint: ordinary tail matches

Change only [check/bodies](src/check/bodies.brp)'s root-match construction. Reuse
`resolve_join_arms` with `return_expectation(signature.return_type)`, then publish
an unannotated root as `CheckedValueBody(ReturnExpression(value))`, where
`value.form` is `Match(join)`, its type is the declared result, its span is
`ParsedMatch.span`, and `join.carried=[]`. Only the function return continues, so
outer-variable reassignment needs no continuation carrier. Preserve captures,
arm statements, arm/call spans, declaration order and binding identities.

For an annotated root, convert those accepted join arms to the existing
`CheckedMatchBody` using one local List builder, before unchanged
`check_execution` sees direct self calls. Keep scalar TCO admission, origin,
rejections and runtime behavior. Void discards still happen after recursion
analysis. Final unannotated Void publication has
`DiscardExpression(Match(join))` in the statements, followed by
`ReturnExpression(LiteralVoid)`; each arm's non-Void value is discarded once.
Tests assert that final shape, original match span and empty carriers. Delete
the replaced `ArmProgress` and `resolve_arms` in this slice; keep the
`ValueExpectation` rationale. No new IR, flag, helper framework or
early-return mechanism is needed. Existing specialize/lower/own/verify/emit
already consume the ordinary value-join route and need no production port.

The historically reviewed ordinary-only specimen forecasts 22 gross additions
and 62 deletions in one production file (net -40), before the local builder and
comment adjustment. Reconstruct actual code from accepted source only after
plan and TDD review; a reconstruction is not evidence of the retained original.
The checkpoint's hard production ceiling is 50 gross additions and a net
reduction. Test/fixture additions forecast 400-650 gross, with a hard
800-gross ceiling, inclusive of changed ordinary expected-output assertions and
at most one 40-line ordinary managed-runtime fixture. These are debits within
the unchanged cumulative scalar ceilings, not a new allowance or offsets for
later work. Report production, tests and fixture lines separately.

First add owning checker tests that fail on the old ordinary product shape:
Int and Void results, captures, statements, exact match span, declared-result
first errors and empty carriers despite reassignment. Keep annotated-root and
negative diagnostic oracles. Update only affected ordinary observers, including
exact generic/constructor instance order; retain all 43 legacy tail-owner test
files and their semantic/negative coverage. Add independent Own/Verify assertions
for a returned owned prefix, a fresh arm-local result and surviving old aliases;
the ordinary managed fixture uses its real `main` and must leak zero objects.
Preserve the existing million-iteration and 0/1/17 scalar-TCO controls.

Record the expected affected C/ARC changes: joins introduce a shared result and
yield assignments; returning a parent-owned prefix adds acquisition and parent
cleanup, while a fresh arm-local keeps the existing empty-carried move. Parent
last-use cleanup and value/owner numbering can change; values, ABI, spans and
evaluation order must not. Review these changes explicitly and require exact C
for unaffected programs. Prove a new oracle by a deliberate fault followed by
restored green, then run the focused and full owning gates. No Python tests,
alternate fixture main, emitted-output rewrite or new feature fixture budget.

SOURCE +3%, the original R0/checkpoint policy and its unresolved hold are
unchanged: no cost setup, baseline/corpus freeze, epoch change or sampling is
authorized. The hold blocks cost acceptance and production landing, not the
separately dispatched TDD/static implementation. The root leases all compiled
jobs and keeps the frozen host binary and standard library unchanged. Reforecast
the complete common-loop work against the cumulative ledger before any later
production writes; stop for scope, ceiling, ownership or host-compiler ambiguity.

## Problem and first executable

The parser accepts while, but [checking](src/check/bodies.brp) at 765 rejects it;
[rendering](src/check/render.brp) at 244 says:

```text
`while` is not supported yet
help: write a recursive function; loops arrive with the loops milestone
```

This is source-inspected, not a newly executed reproduction. Existing scalar
TCO uses a function-wide execution flag and returns/backedges in one exit type.
First replace that representation without broadening accepted source. Then
admit flat while with String carriers and unmanaged carriers, using the same
loop path. The smallest feature fixture uses actual target APIs:

```blorp
import:
    io: print

func replace(seed: String, run: Bool) -> String:
    var running = run
    var current = seed
    while running:
        current = 7.to_string()
        running = False
    current

func main() -> Int:
    seed = 1.to_string()
    print(replace(seed, False))
    print(replace(seed, True))
    print(seed)
    0
```

Expected: stdout `1\n7\n1\n`, empty stderr, status zero. Use the normal e2e
entrypoint and Makefile-selected compiler. No integer less-than, if, not,
new standard-library function or grammar expansion is needed.

## Products and construction

The common-loop destination gives ordinary functions statements and one result
expression. Their tail matches use CheckedExpr.Match/CheckedJoin,
ConcreteExpr.Match and existing LoweredJoin, followed by the single function
result. Retire ordinary FunctionArm/FunctionMatch/FunctionTail products and
walkers. LoopBlock alone
retains Exit or Match terminals; its arms end in Break/Recur directly. M2 joins
still yield, and loop arms cannot recursively contain another match terminal.

Preserve the explicit source root-tail distinction through annotation analysis:
annotated root matches become LoopMatch before ordinary normalization. Otherwise
a valid direct self call would become a rejected nested join. Reuse
resolve_join_arms with declared return_expectation: SourceAnnotation for a known
result, VoidTail for Void. Keep Void discards after recursion analysis and before
publishing the generic result. Ordinary tail joins have carried=[] by
construction; retain ParsedMatch.span and every original arm/call span. No
persistent provenance flag, generic framework or backend shape heuristic.

For example, this ordinary tail match returns an owned prefix on one branch:

```blorp
pure func choose(flag: Bool) -> String:
    held = 1.to_string()
    match flag:
        True: held
        False: 2.to_string()
```

```text
Before: Match flag
    True  -> Return(held_owner)
    False -> fresh = to_string(2); Drop(held_owner); Return(fresh_owner)
After: P = Join flag, carried=[]
    True  -> Acquire(held); Yield(new_owner)
    False -> fresh = to_string(2); Yield(move fresh_owner)
Drop(held_owner)
Return(P)
```

These are schematic ownership operations. Returning the owned prefix adds a
retain/release pair; a fresh arm-local result can still move through the existing
empty-carried join fast path. Parent last-use cleanup can release an unused
prefix earlier. Supported value/IO semantics remain fixed; ARC counts, C and
compiler costs must be measured rather than called identical.

Checked self-loop origin contains only annotation Span, ordered formal
BindingIds and the checked loop body. check/bodies supplies the formal ids to
check/recursion; retain generic, non-tail, nested-tail and no-self-call rules.
Specialization performs annotation admission once using sealed representation
facts, then erases the origin. Managed TCO remains rejected, including managed
intermediates and M2 join results/carriers, with exact existing diagnostics.

At specialize:2696, unions and records are already sealed instances. Move the
existing final `.layout` projections from program publication to immediately
before function translation, once per program; pass and publish those same
concrete lists. Keep instance tables for identity/type translation. Never map
layouts per function or pass instance lists to value_ownership.

```blorp
union_layouts = prepared.unions.map(
    pure func(instance: UnionInstance): instance.layout,
)
record_layouts = prepared.records.map(
    pure func(instance: RecordInstance): instance.layout,
)
-- translate_function receives these same layouts for admission.
-- SpecializedProgram publishes these same layouts afterward.
```

Concrete LoopValue supplies the primary result without a fabricated checker
binding. TCO has LoopValue(loop) as its result; while discards its Void loop
result and publishes its carried bindings. While admission permits String and
NoOwnership header representations; other managed carriers stay rejected at
the specialization boundary that has their concrete representation.

The representative products use one ordinary result and closed loop terminals.
Keep lowered/owned functions flat. This 63-line specimen replaces the historical
87/82-line dual-tail prototype; it is not whole-change LOC evidence.

```blorp
fixed union LoweredStep:
    Define(ValueDefinition)
    Join(LoweredJoin)
    Loop(LoweredLoop)


fixed union LoopExit:
    Break(LoopOutputs)
    Recur(List[ValueId], Span)


fixed record LoopOutputs {
    value: ValueId,
    carried: List[ValueId],
    span: Span
}


fixed record LoopArm {
    label: MatchLabel,
    steps: List[LoweredStep],
    exit: LoopExit
}


fixed record LoopMatch {
    scrutinee: ValueId,
    owner: UnionInstanceId,
    arms: List[LoopArm]
}


fixed union LoopTail:
    Exit(LoopExit)
    Match(LoopMatch)


fixed record LoopBlock {
    steps: List[LoweredStep],
    tail: LoopTail
}


fixed record LoopHeader {
    parameter: ValueParameter,
    initial: ValueId
}


fixed record LoweredLoop {
    headers: List[LoopHeader],
    result: ValueParameter,
    carried: List[ValueParameter],
    body: LoopBlock,
    reads: List[ValueId]
}


fixed record LoweredFunction {
    signature: FunctionSignature,
    steps: List[LoweredStep],
    result: ValueId
}
```

## Entry, edges and ownership

Let PRE be the live values/owners at the loop site, H its ordered header
parameters, and P its primary result plus carried continuation parameters.
P belongs to the parent step interval; H belongs to the nested loop interval.
Capture PRE before publishing either H or P into nested visibility. Reserve
P identities without making them available inside the loop. Header initial
sources are PRE values, evaluated in source order once. H and P have independent
arity/types: scalar TCO has function-arity H and one-result P, including H=0.

Mint H and bind original formal/source header BindingIds to it before lowering
the complete original prefix and tail. Currently lower_function:926 lowers
the prefix against ABI captures; after conversion that prefix is inside the
loop and reads H. Extend existing pending-block completion and step walkers,
with typed terminal adapters; no new pass or duplicated ownership analysis.

For managed entry, acquire one internal H obligation for every incoming
occurrence, even repeated aliases. The first feature conservatively protects
every live PRE owner throughout the loop, including owned initial inputs.
Do not move those owners into H. Borrowed ABI inputs acquire internal H owners
without retiring caller obligations. Ordinary parent cleanup retires eligible
PRE owners only after the loop completes; this is not a minimum-retain pilot.

H and iteration locals share the existing loop-local owner interval. On every
Recur/Break: evaluate and capture all outgoing occurrences; acquire each
outgoing managed occurrence; retire old header and remaining local obligations;
publish the whole destination transfer batch; continue/break. This first
feature acquires even an owned source before dropping its old obligation;
there is no loop-local move fast path. Duplicate destinations need duplicate
obligations. A projected String child is acquired before retiring its source
parent. No cleanup follows a backedge.

Scalar preparation may exercise managed P only through raw phase tests over the
common Loop and existing M2 output batch; source scalar eligibility and unmanaged
H stay unchanged. Extract the narrow acquisition core: keep M2's local-result
move fast path outside it, and acquire every loop P occurrence even when there
is only one. Test two aliased outputs from a loop-local owned String that must
retire on Break, a separate single-output case, and an independent PRE String
reused after the loop. PRE aliases alone do not prove local retirement.

The while condition executes at the header on every iteration, including the
initial and final false check, preserving impure calls and their order. Its
condition-only temporaries receive normal last-use cleanup while H remains
live. The false edge then transfers current H to carried P, acquires outputs
before retiring H/remaining locals, and breaks with Void as the primary result.
The true arm executes the flat source body then recurs with updated headers.

The condition must have the foundation's designated Bool type, never Int
truthiness or a same-shaped user union. Reuse the Boolean feature's single
producer/consumer route: `foundation.designated.boolean` in check/check:79 ->
resolve_functions -> ResolutionContext.boolean in check/callables:204 ->
while resolution in check/bodies. Its DesignatedBoolean[VariantId] already
contains typed true_variant/false_variant; the expected type is their owner's
UnionType. Use the existing Boolean operand constraint/validation path. Build
the loop's True/False labels from those ids, translate them once through the
existing checked-to-concrete variant translation, and pass concrete identities
unchanged to lower/own/verify/emit. No spelling lookup or second Bool authority.

Independent verification consumes each edge batch once and checks availability,
arity/types, transfer multiplicity and complete retirement of H/iteration/arm
owners. Pass the existing loop-entry snapshot to exit verification and require
all PRE owners live at entry to remain live there. Current enter:2319 replaces
the enclosing-discharge policy, so a LoopMatch arm must not bypass this check.
No global KeepsEnclosing flip, new discharge-mode variant or frame registry.

## Emission and scope

Current append_function:2054 chooses a while wrapper from FunctionExecution;
append_exit:2033 assigns mutable ABI slots. Replace that with common loop-step
emission through the existing operation walker:

```c
/* Expected shape; schematic identifiers. */
int64_t result;
int64_t header=initial;
while (1){
    const int64_t current=header;
    /* Original prefix executes here using current. */
    /* Break: result=captured_result; break; */
    /* Recur: header=captured_next; continue; */
}
return result;
```

Outgoing immutable captures preserve simultaneous swaps/duplicates before
assigning header/result storage. Zero-header infinite TCO needs no fabricated
header or base edge. Review expected annotated-TCO C changes individually.
Programs affected by neither TCO nor ordinary-tail normalization retain exact C.
Affected ordinary matches have enumerated expected C, ARC and value/owner-ID changes;
ABI and values remain fixed. No blanket C normalization. No LoopInput, return-destination
mode, numbering-preservation scheme or backend TCO-shape heuristic.

A one-level LoopMatch uses the existing switch structure inside while. Recur
arms assign headers then continue the while; Break arms assign outputs then
break the switch. The unconditional break after that switch exits the while
only for those Break paths, because every other arm continued. This distinction
needs no LoopId, flag or destination mode. A direct Exit(Break) breaks the
while directly; captures still precede every assignment.

```c
while (1){
    /* Header snapshots and prefix. */
    switch (scrutinee){
        case recur_tag: { /* Captures/cleanup, header assignments. */ continue; }
        case break_tag: { /* Captures/cleanup, result assignments. */ break; }
    }
    break; /* Break arms left the switch; now leave the while. */
}
```

First while bodies may contain existing yield-only M2 joins, but no explicit
break/continue, nested loops, return/propagation exits or nested tail matches.
List for, ranges, source-walk migration, managed/generic TCO and recursive
managed carriers remain later slices. Neither first slice completes M3.

## Inventory and prospective ceilings

The nine direct production modules and the exact existing rewrite/removal
regions are below. Anchors refer to the M2 patch. Counts include physical
function lines; complete regions also include intervening spacing/comments.

| Owner | Existing region and accounting | Addition/replacement |
| --- | --- | --- |
| [utils/syntax](src/utils/syntax.brp):317 | FunctionExecution: 3 removed | None |
| [check/model](src/check/model.brp):237,269,481 | Exit/flag products; call walker rewritten | Closed products/origin; retain call discovery |
| [check/recursion](src/check/recursion.brp):149,212,220,239 | tail_exit 17, recurs 6, body_recurs 11, check_execution 44; rewrites, not savings | Header identities and checked loop conversion; retain all rejections |
| [check/bodies](src/check/bodies.brp):959,996 | Publication and Void normalization rewritten | Supply formal identities; normalize both body kinds |
| [specialize](src/specialize/specialize.brp):1858,2542,2561 | exit_types 11, translate_exit 17 rewritten; execution field/copy removed | Products, request/type walks, admission and loop translation |
| [lower](src/lower/lower.brp):578,586,901 | exit_span 6 and lower_exit 38 rewritten; old products 40 replaced | Draft products 63; common loop completion/terminal lowering |
| [own](src/own/own.brp):1326 | Admission functions 101; complete region 108 relocated, no net-saving credit | Common loop insertion/transfers; adapt shared walkers |
| [verify](src/verify/verify.brp):2037,2098 | verify_exit 59 rewritten; obsolete preflight functions 133, complete region 141 removed | Structural headers/edges, completeness and PRE protection |
| [emit](src/emit/emit.brp):2033,2054,2222 | append_exit 19 and append_function 30 rewritten; opening/closing switches 10 become 2 | Common loop emission and existing inventory traversal |

There are 39 direct execution/backedge unit consumers (check 1, emit 7, own 5,
verify 25, helper 1), not 39 total affected tests. Inventory additional
lower/specialize observers and preserve their exact oracles before edits.
Managed condition checking also consumes the existing Boolean expression
validation path; check/check and check/callables are dependency-route anchors,
not new scalar execution consumers. Reuse its existing mismatch kind/renderer.
The prior +175 net estimate is withdrawn. Seven duplicate function regions
contain 286 body lines, about 300 including separators. Keep the thin known-result
checker adapter and repurpose shared mechanics for LoopMatch; do not count all
300 as free savings. Ordinary products and observers provide further retirement.

The historically reviewed broad draft had 774 gross additions and 568 deletions
across six production owners, before Own/Verify/Emit were ported. Its original
checkout is currently unavailable after interruption; these historical counts
and the last forecast below are not a current patch-identity claim. Root and
the primary session are checking recovery; preserve any recovered source and
ignored evidence without presenting reconstructed files as retained evidence.
That draft left only 376 gross additions under the approved whole ceiling;
the last independent Own (190-240) and Verify (180-230) forecasts already
consumed 370-470 before Emit. That draft is not an accepted working increment
or a feasible whole forecast. The earlier roughly
1,100/+250 planning point and 1,240/+406 uncertainty do not authorize more writes.
Complete only the independently working checkpoint above, report actual
retirement, and reforecast the whole remainder before resuming loop algorithms.
The checkpoint and every later common-loop change share one cumulative
1,150-gross/+350-net production ledger and 1,600-gross test ledger. No cap reset,
offset, borrowed feature budget, compressed formatting or deleted coverage.
The following hard ceilings remain unchanged.

| Slice | Production physical additions/net growth | Test additions | Normal feature fixtures |
| --- | --- | --- | --- |
| Scalar preparation | at most 1,150 gross / +350 net | at most 1,600 gross | Existing TCO behavior/rejections |
| Later managed String while | at most 750 gross / +600 net | at most 1,600 gross | at most 3, at most 120 total source lines |

Report actual production/test gross and net separately, including replacements.
No offsets between slices, compressed formatting, deleted coverage or borrowed
feature budget. Reassess before exceeding a ceiling or adding a mechanism.

SOURCE preparation's proposed cost role is +3% allocations and normal min3
retired instructions per input, with the existing original-checkpoint and
source-proxy policy UNWAIVED. A current-B-only baseline proposal is conditional
on the unanswered user policy question: do not freeze or sample until resolved.
Identify the policy's actual checkpoints; do not invent an automatic R0 gate.
Expected TCO and ordinary-tail-match C changes require explicit review, not
blanket normalization.

Managed FEATURE has a separate prospective +5% target/+10% hard shared-input
contract and new-fixture absolute ceilings fixed before implementation. These
are not borrowed permission, automatic ceiling changes or host-leak exceptions.
Freeze/rebuild matched sources under one approved toolchain and record hashes,
normal min3 samples and allocations serially. Owned inputs are self-compile
proxies until self-compilation works; retain raw evidence under ignored build/.

## Acceptance and stop rules

Scalar: phase tests for origin erasure/admission, fresh H/P/PRE visibility,
differing arities, zero arguments, swaps, duplicate occurrences, repeated prefix
execution and exact old semantic rejection message/help/span. Review all TCO
fixture C changes; catalogue ordinary-tail changes and require exact C for
unaffected programs. No managed-TCO widening.

The immediate checkpoint has the independent acceptance contract above. For
later complete ordinary convergence, pin declared-result first-error spans,
Void discards, empty carriers despite outer-var reassignment, and exact
generic/constructor instance IDs. The extra result-type inventory visit must
not reorder unique
instances. Forty-three unit files refer to retired tail products: port every
semantic/negative oracle, replacing per-arm prefix-drop traces with exact branch
acquisition and parent cleanup. Keep missing/double cleanup, wrong-owner,
unavailable-sibling and borrowed-child negatives, plus the actual million/
0/1/17 output checks. No duplicate stress fixture. Extra P/owner facts and ARC
pairs may affect costs; unchanged SOURCE +3% and original-checkpoint rules apply.

Managed: test entry acquisition/caller survival, unchanged/fresh carriers,
captured aliases, repeated borrows, duplicate/swap transfers, unused locals,
return after loop and natural false Break. Test projected String children from
already supported managed records, not new managed header types. Check impure
condition calls execute once per attempted iteration and false-edge cleanup
precedes continuation. Use granular own tests and independently malformed raw
verifier inputs for missing/double acquisition, wrong arity/type, early header
retirement, live old owners, unavailable P/H and PRE discharge through LoopMatch.

Named condition oracles: test_while_accepts_designated_bool_condition and
test_while_uses_designated_constructor_ids_under_shadowing check canonical Bool
and its typed True/False branches. test_while_rejects_int_condition and
test_while_rejects_same_shape_user_union_condition require
ValueRejection(ExpressionTypeMismatch) with expected_site=BooleanOperand,
expected=the designated Bool type and actual=the rejected type. Both pin the
complete condition-expression span (not the while keyword), message
`Boolean operand must have type Bool`, and help
`use True, False, or an expression that returns Bool`. Add
test_while_rechecks_impure_condition_before_false_exit for n+1 evaluations and
test_loop_match_break_exits_while_after_switch for the structural break oracle.

Use runtime-helper native occurrence counters under the existing direct-C
exception, plus normal-entrypoint e2e output/status/stderr and sanitizer checks.
No generated-language alternate main or calls to internal generated functions.
Prove key oracles with deliberate mutations. Exercise 16/32/64/128 scaling,
record default-toolchain C nesting depth and a moderate nesting stress case
using supported joins; this does not admit nested source loops.

After approved baseline policy and implementation, first run focused owning
unit suites using a fresh repository host, then:

```bash
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_tail_recursion.brp blorp_2/test/unit/test_own/test_tail_recursion_phases.brp blorp_2/test/unit/test_verify/test_tail_recursion.brp
make -C blorp_2 test
```

Add the new owning suites to the focused command. Serialize compiled gates and
cost work; preserve exact commands, provenance, failures and oracle limits.
Stop for an unclear ownership boundary, repeated whole-body/layout scans,
unapproved mechanism, host defect or ceiling breach. Root integrates after
independent code-reviewer/test-runner evidence. This docs slice needs only
link/path checks and git diff --check; plan review precedes its separate commit.
