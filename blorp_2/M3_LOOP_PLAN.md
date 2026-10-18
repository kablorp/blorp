# M3: common loops, then managed String while

## Status, dependencies and review boundary

Plan approved by root and independent source_port review, 2026-10-18, including
the architecture and prospective ceilings below. Commit this documentation
separately. Implementation requires its own bounded dispatch; the first scalar
dispatch records baseline characterizations before production edits. This
approval authorizes no cost setup, baseline freeze or sampling while SOURCE
policy and the accepted measurement baseline remain unresolved.

This worktree starts at accepted unary commit
`db8abb15af4250eba1ad4c6d3efc8171cf35adaf`. Implementation depends on M2 carried
joins: the inspected staged binary patch in `bootstrap-carried-current` has
SHA-256 `b67726f0943af21afbf4dfdb71462a241c315c5b15f9c5d25e9133a7e6622778`
(`git diff --cached --binary | shasum -a 256`). This is a patch digest, not a
commit. Source line anchors below refer to that M2 dependency snapshot; the
db8 base does not contain it. Scalar implementation may proceed in a new owned
worktree stacked only on this exact reviewed patch, explicitly labelled a
prospective dependency. Preserve the patch and source provenance without
claiming M2 accepted. Final gates and publication wait for reconciliation and
review against the actual accepted M2 integration; refresh anchors/provenance
there. Do not modify the active M2/unary worktrees, campaign inputs or pins.

Scalar preparation does not depend on the Boolean feature. Managed while
reuses its accepted designated-Bool route (root review identifier `800b`), or
requires review of a bounded port of that same route if it has not landed.
Do not create a parallel Bool channel. The unresolved SOURCE baseline policy
does not block this plan or static consumer inventory; cost gates stay pending.

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

ConcreteFunctionBlock has statements and a Return or FunctionMatch terminal.
Function arms end in a returned expression. LoopBlock has statements and an
Exit or Match terminal; each match arm ends in LoopExit directly. M2 joins
still yield. A backedge cannot occur in a function or join terminal, and loop
arms cannot recursively contain another match terminal.

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
binding. TCO becomes Return(LoopValue(loop)); while discards its Void loop
result and publishes its carried bindings. While admission permits String and
NoOwnership header representations; other managed carriers stay rejected at
the specialization boundary that has their concrete representation.

The representative lowered products below replace the old execution/exit
products. Keep lowered/owned functions flat; no FunctionBlock wrapper there.
The earlier 87-line prototype had that wrapper. Removing its six-line block
including spacing and adding one flat field produces this 82-line specimen.
The comparable old declarations occupy 40 physical lines: this product hunk
adds 42, before any algorithms. Concrete retains its function block boundary.

```blorp
fixed union LoweredStep:
    Define(ValueDefinition)
    Join(LoweredJoin)
    Loop(LoweredLoop)


fixed record FunctionArm {
    label: MatchLabel,
    steps: List[LoweredStep],
    value: ValueId
}


fixed record FunctionMatch {
    scrutinee: ValueId,
    owner: UnionInstanceId,
    arms: List[FunctionArm]
}


fixed union FunctionTail:
    ReturnValue(ValueId)
    MatchValue(FunctionMatch)


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
    tail: FunctionTail
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
header or base edge. Review expected annotated-TCO C changes individually;
ordinary non-loop fixture C remains exact. No LoopInput, return-destination
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
| [lower](src/lower/lower.brp):578,586,901 | exit_span 6 and lower_exit 38 rewritten; old products 40 replaced | New products 82; common loop completion/terminal lowering |
| [own](src/own/own.brp):1326 | Admission functions 101; complete region 108 relocated, no net-saving credit | Common loop insertion/transfers; adapt shared walkers |
| [verify](src/verify/verify.brp):2037,2098 | verify_exit 59 rewritten; obsolete preflight functions 133, complete region 141 removed | Structural headers/edges, completeness and PRE protection |
| [emit](src/emit/emit.brp):2033,2054,2222 | append_exit 19 and append_function 30 rewritten; opening/closing switches 10 become 2 | Common loop emission and existing inventory traversal |

There are 39 direct execution/backedge unit consumers (check 1, emit 7, own 5,
verify 25, helper 1), not 39 total affected tests. Inventory additional
lower/specialize observers and preserve their exact oracles before edits.
Managed condition checking also consumes the existing Boolean expression
validation path; check/check and check/callables are dependency-route anchors,
not new scalar execution consumers. Reuse its existing mismatch kind/renderer.
The prior +175 net estimate is withdrawn. The following are prospective stop
ceilings chosen for review, not predictions justified by the old-region sums.

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
Expected TCO C changes require explicit review, not blanket normalization.

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
fixture C changes; require ordinary non-loop C identity. No managed-TCO widening.

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
