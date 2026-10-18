# M3: common loops, then managed String while

## Status, dependencies and review boundary

The ordinary-tail preparation has passed its focused 16-test emitter suite and
43-suite, 787-test owner batch. Its remaining acceptance, SOURCE cost evidence
and production landing are pending. Its actual ledger is recorded below.
The next checkpoint is the smaller scalar runtime-loop rescope reviewed by root
and an independent compiler expert on 2026-10-18. Commit this amendment separately
after plan review; phase tests and implementation need their own dispatch.
The broader common-loop checkout is currently unavailable after interruption;
root and the primary session are checking recovery. Preserve any recovered
source and ignored evidence. This checkpoint does not approve resuming that
draft or establish that the deferred early-IR convergence fits the whole cap.
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

## Ordinary-tail preparation and current acceptance

Actual production is 35 additions / 61 deletions (net -26) in two files,
including the three model-comment corrections. Tests are 687 additions /
480 deletions in 41 files, with no fixture additions. The owning emitter suite
passed 16/16 and the owner batch passed 787/787, both with empty stderr and status
zero. The earlier 784-pass/3-fail batch is retained: three old ordinary C-shape
oracles were then ported with 7 additions / 5 deletions and independently
reviewed. The checker-first RED was the expected 22 passes / 2 ordinary-shape
failures; annotated controls stayed green. These results do not substitute for
the remaining oracle mutation, broad/runtime gates or matched cost acceptance.

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

## Next checkpoint: one scalar runtime loop

Keep the current checked annotation analysis and checked/concrete source-tail
products. Specialize admits scalar TCO once from sealed representation facts;
Lower consumes the existing concrete execution marker once and erases it while
constructing the common runtime Loop. Defer checked/concrete product and early
origin retirement. This smaller checkpoint proves the runtime dataflow without
claiming full early-IR convergence or admitting source while.

Published lower/owned functions have steps/operations and one result. There is
one common runtime Loop, with no legacy tail fallback in Own, Verify or Emit.
The original prefix executes inside every iteration after fresh H identities
replace the original formal bindings. Reuse existing pending completion,
last-use, acquisition, verification and switch mechanics; no generic CPS/SSA
framework, parallel loop path or new phase is authorized.

## Problem and first executable

The parser accepts while, but [checking](src/check/bodies.brp) at 765 rejects it;
[rendering](src/check/render.brp) at 244 says:

```text
`while` is not supported yet
help: write a recursive function; loops arrive with the loops milestone
```

This is source-inspected, not a newly executed reproduction. Existing scalar
TCO uses a function-wide execution flag and returns/backedges in one exit type.
First replace its runtime representation without broadening accepted source.
Later FEATURE first admits flat while with unmanaged headers and a real main
checking zero/one iterations with Int output `1\n7\n`; the next stage admits
String headers and managed temporaries on the same loop path. Both stages share
the separate feature ceiling below. The smallest managed fixture uses actual
target APIs:

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

Ordinary tail matches already use CheckedExpr.Match/CheckedJoin,
ConcreteExpr.Match and LoweredJoin. The next checkpoint keeps CheckedBody,
ConcreteBody and the existing execution marker upstream of Lower for annotated
source-tail analysis. Retire lower/owned function-tail products and their
consumer walkers. LoopBlock alone retains Exit or Match terminals; its arms end
in Break/Recur directly. M2 joins still yield, and loop arms cannot recursively
contain another match terminal. Own, Verify and Emit consume only this common
runtime shape, not a legacy annotated-tail fallback.

Preserve the explicit source root-tail distinction through annotation analysis:
annotated root matches retain CheckedMatchBody through unchanged check_execution.
Otherwise a valid direct self call would become a rejected nested join. Reuse
resolve_join_arms with declared return_expectation: SourceAnnotation for a known
result, VoidTail for Void. Keep Void discards after recursion analysis and before
publishing the generic result. Ordinary tail joins have carried=[] by
construction; retain ParsedMatch.span and every original arm/call span. No
persistent downstream provenance flag, generic framework or backend shape
heuristic. Lower alone converts the accepted annotated root to its LoopMatch.

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

The checked producer retains its existing annotation marker and accepted body;
check/recursion keeps generic, non-tail, nested-tail and no-self-call rules.
Specialize performs annotation admission once using sealed representation facts.
The concrete marker then reaches Lower only to construct the common Loop and is
erased there. Do not add checked/concrete loop schemas in this checkpoint.
Managed TCO remains rejected, including managed intermediates and M2 join
results/carriers, with exact existing message, help and span.

Keep the existing preorder type inventory and request order: append_value_types
fixes concrete instance IDs and C names. Admission instead preserves lowered
evaluation order: ordinary expression children before their parent, and each
join's result/carriers before its arm bodies. Do not reuse the preorder inventory
as an eligibility traversal or reorder instances to avoid a new narrow walk.

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

Lower reserves the Loop's primary result without a fabricated checker binding;
the unchanged concrete body is its source, not a new Concrete LoopValue schema.
Early checked/concrete loop products and their origin erasure are deferred and
need a new bounded forecast before writes. Later while uses the same runtime
Loop, discards its Void primary result and publishes carried bindings. Its
source admission permits String and NoOwnership header representations; other
managed carriers remain rejected at the specialization boundary that owns their
concrete representation. Raw managed-output tests confer no managed-TCO or
managed-header source eligibility in this scalar checkpoint.

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

Capture the actual live PRE obligations, not only an ordinal limit. Every loop
edge must preserve each captured obligation, including an edge in a LoopMatch
arm after nested enter replaces its enclosing-discharge policy.

For later managed entry, acquire one internal H obligation for every incoming
occurrence, even repeated aliases. The first feature conservatively protects
every live PRE owner throughout the loop, including owned initial inputs.
Do not move those owners into H. Borrowed ABI inputs acquire internal H owners
without retiring caller obligations. Ordinary parent cleanup retires eligible
PRE owners only after the loop completes; this is not a minimum-retain pilot.

H and iteration locals share the existing loop-local owner interval. On every
Recur/Break: evaluate and capture all outgoing occurrences; acquire each
outgoing managed occurrence; retire old header and remaining local obligations;
publish the whole destination transfer batch; continue/break. Every Loop,
including a scalar raw managed-output test, acquires even an owned source before
dropping its old obligation;
there is no loop-local move fast path. Duplicate destinations need duplicate
obligations. A projected String child is acquired before retiring its source
parent. No cleanup follows a backedge.

Scalar preparation may exercise managed P only through raw phase tests over the
common Loop and existing M2 output batch; source scalar eligibility and unmanaged
H stay unchanged. This is no permission to admit managed TCO, source managed
headers or managed H implementation in the scalar slice. Extract the narrow
acquisition core: keep M2's local-result
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

The next checkpoint touches five production owners plus the reviewed ordinary-tail
preparation in Check's bodies/model modules. Checked/concrete product retirement,
check/recursion conversion and utils/syntax retirement are deferred; their old
whole-change forecast does not authorize writes.

| Owner | Bounded change | Additional physical additions |
| --- | --- | --- |
| [specialize](src/specialize/specialize.brp):2542 | One scalar admission walk, sealed layout projections; preserve source products and instance order | 233 observed; 240 maximum |
| [lower](src/lower/lower.brp):747,926 | One pending Loop, fresh H/P intervals, original prefix/body conversion and shared step walkers | 210-250 |
| [own](src/own/own.brp):1082,1326 | Common insertion/edge batches; relocate admission, with no move credit | 282 in uncompiled syntax-correction scratch; re-estimate before further additions |
| [verify](src/verify/verify.brp):1589,2037,2319 | Common structural/edge verification and captured PRE protection; retire duplicate origin preflight | 210-250 |
| [emit](src/emit/emit.brp):1936,2054,2222 | Common loop operations, outgoing captures, one switch/loop exit and inventory traversal | 162 observed; re-estimate before further additions |

The original production forecast was 850-1,020 additional gross / +100-280 net.
Keep the cumulative internal production stop at 1,085 additions / +274 net,
inside the unchanged original 1,150/+350 ceiling. Count actual rewritten/removal
regions only: relocating Own's admission is not a net saving, and deleting old
draft code earns no credit. Stop earlier if an owner forecast fails.

**Prospective syntax-compatibility correction, 2026-10-18.** The first focused
host check stopped before any test: 17 diagnosed loop-body `?=` sites and inline-block
syntax produced 31 setup diagnostics. This is no semantic RED. Use the existing
explicit `match`/first-error/break pattern; do not change the host or language.
One private Verify header builder may return existing `KnownValue` after checking
next H ordinal, actual PRE lookup, exact concrete type and `NoOwnership`, in that
order. Publish one row only on success. Preserve sequential transfer consumption,
all acquisitions before retirement, and PRE protection before local-owner checks.

The complete readable, uncompiled scratch correction has **1,084 production additions /
834 deletions / +250 net**, including 35 additions in the Check preparation.
Own is 282/335; Verify is 222/269; Emit remains 162/81. This refreshes Own's old
200-230 and Emit's old 110-140 forecasts; it adds no mechanism or cumulative
allowance. The unchanged internal stop leaves **one gross addition and 24 net**;
owner rows are not stackable allowances. Review the exact scratch patch before
tracked writes and re-estimate before any further addition. All source eligibility,
fixture, test and resource gates remain unchanged.

**Prospective test-only rescope, 2026-10-18; root and independent review approved.** The old
1,587 internal / 1,600 hard test-addition forecast did not cover the actual
independent raw-IR ports. A representative explicit Join port adds 25/deletes24
lines while preserving all 47 callbacks, 27 rejection oracles and the exact
unknown-record diagnostic/span. The closure includes 25 inline old match-tail
construction/update sites totaling 425 literal lines, plus named wrappers and
pattern readers. Ordinary source cannot generate these malformed resource
states; replacing them with successful producer output would weaken coverage.

Replace the old scalar test ceilings with **one cumulative hard ceiling of
3,300 physical additions / +1,100 net**. This includes every prep, port and new
oracle. The earlier 2,400/+900 ceiling and 1,883-2,283 forecast did not cover the
complete remaining raw-IR ports. The recovered static composition has 2,135
test additions / 1,651 deletions (+484), before four unfinished suites preserving
110 original callbacks. Direct ports forecast 500-700 further additions; the
missing independent H/P/PRE edge tests forecast another 150-250. The resulting
2,785-3,085 cumulative forecast fits this replacement ceiling. These are static
counts and forecasts, not compiled or accepted evidence.

The net ceiling is an independent stop: +484 leaves 616 net lines; at the upper
950-addition forecast, at least 334 deletions are required. Before canonical
test writes, review a scratch representative ADD/DEL/net count and the mapping
of preserved callbacks and resource oracles. Use direct raw constructions;
producer-derived accepted products cannot replace malformed-IR tests.

Specialize's recovered 233 additions exceed its earlier 120-150 owner forecast.
Its refreshed 240-addition maximum leaves seven lines for corrections within
the unchanged whole-production 1,085/+274 internal and 1,150/+350 hard stops.
Before syntax correction, static whole production was 997 additions /
835 deletions (+162); the corrected forecast above supersedes that snapshot.
Further production work needs a forecast within the remaining allowances. Report
complete production, test and fixture ADD/DEL/net separately as ports close.

This replaces the cumulative test budget and refreshes Specialize's owner
forecast for the same scalar common-loop checkpoint. Whole-production caps,
source eligibility, fixtures and resource gates stay unchanged;
SOURCE cost policy is a separate decision. Preserve every distinct resource oracle; use existing
identity seeds and direct fixtures where useful, with no output-derived raw
inputs, adapter framework, dual tail path, compressed formatting or deleted
coverage. A separately reviewed plan amendment precedes further test writes.

The actual old-tail retirement closure is 59 unit/helper files, with 286 lines
mentioning the affected products or fields: six Lower suites, fifteen Own,
twenty-seven Verify, eight Emit and three shared helpers. The smaller
execution/backedge-keyword inventory of 24 files is insufficient. Preserve each
semantic/fault oracle in this complete closure under [test/unit](test/unit/):

- Helpers (3): `join_inputs.brp`, `managed_union_inputs.brp`,
  `ownership_inputs.brp`.
- `test_lower/` (6): `test_float_phases.brp`, `test_join.brp`,
  `test_lower.brp`, `test_managed_union.brp`, `test_option_contracts.brp`,
  `test_record_update.brp`.
- `test_own/` (15): `test_constants.brp`, `test_current_directory.brp`,
  `test_file_read.brp`, `test_generic_list_phases.brp`, `test_int_equals.brp`,
  `test_join.brp`, `test_managed_union.brp`, `test_own.brp`,
  `test_record_lower.brp`, `test_string_concat.brp`,
  `test_string_from_codepoint.brp`, `test_string_literals_phases.brp`,
  `test_tail_recursion.brp`, `test_tail_recursion_phases.brp`,
  `test_write_file.brp`.
- `test_verify/` (27): `test_arguments.brp`, `test_boolean_contracts.brp`,
  `test_carried_join.brp`, `test_direct_union_payloads.brp`, `test_file_read.brp`,
  `test_float_ownership.brp`, `test_list_membership.brp`,
  `test_list_ownership.brp`, `test_managed_records.brp`, `test_managed_union.brp`,
  `test_multiple_union_fields.brp`, `test_multiple_union_ownership.brp`,
  `test_nested_payload.brp`, `test_option_ownership.brp`, `test_owned_prefix.brp`,
  `test_owned_scrutinee.brp`, `test_record.brp`, `test_record_update_ownership.brp`,
  `test_recursive_unions.brp`, `test_result_ownership.brp`,
  `test_string_concat.brp`, `test_tail_recursion.brp`, `test_union.brp`,
  `test_verify.brp`, `test_void_print_ownership.brp`, `test_void_returns.brp`,
  `test_write_file.brp`.
- `test_emit/` (8): `test_builtin_functions.brp`, `test_emit.brp`,
  `test_function_recursion_ownership.brp`, `test_generic_ownership.brp`,
  `test_list_phases.brp`, `test_managed_union.brp`, `test_recursive_unions.brp`,
  `test_string_literals_ownership.brp`.

Managed condition checking later reuses the existing Boolean validation route;
check/check and check/callables are dependency anchors, not scalar consumers.
Reuse the existing mismatch kind/renderer. All older net/duplicate-region
estimates are superseded by this bounded forecast, not counted as free savings.

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
The working ordinary prep and the reviewed runtime-loop rescope replace that
unbuildable draft. Reforecast the deferred early-IR remainder before any of its
writes; the runtime rescope does not establish that it fits.
The checkpoint and every later common-loop change share one cumulative
1,150-gross/+350-net production ledger and 3,300-gross/+1,100-net test ledger. No cap reset,
offset, borrowed feature budget, compressed formatting or deleted coverage.
The production ceilings remain unchanged; the scalar test rescope above is the
sole replacement for its earlier internal and hard test ceilings.

| Slice | Production physical additions/net growth | Test additions | Normal feature fixtures |
| --- | --- | --- | --- |
| Scalar preparation | at most 1,150 gross / +350 net | at most 3,300 gross / +1,100 net | Existing TCO behavior/rejections |
| Later managed String while | at most 750 gross / +600 net | at most 1,600 gross | at most 3, at most 120 total source lines |

Report actual production/test gross and net separately, including replacements.
No offsets between slices, compressed formatting, deleted coverage or borrowed
feature budget. Reassess before exceeding a ceiling or adding a mechanism.

SOURCE preparation follows the user-approved
[fixed-baseline contract](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance): +3%
allocations and normal min3 retired instructions per input and original
construction-checkpoint proxy against one named accepted B. Root freezes exact
roles before setup/samples; historical R0 failures remain recorded, with
cumulative trends reported separately. No automatic roll after failure.
Expected TCO and ordinary-tail-match C changes require explicit review, not
blanket normalization.

Managed FEATURE has a separate prospective +5% target/+10% hard shared-input
contract and new-fixture absolute ceilings fixed before implementation. These
are not borrowed permission, automatic ceiling changes or host-leak exceptions.
Freeze/rebuild matched sources under one approved toolchain and record hashes,
normal min3 samples and allocations serially. Owned inputs are self-compile
proxies until self-compilation works; retain raw evidence under ignored build/.

## Acceptance and stop rules

Scalar begins with an existing-style phase-test-first packet, separately
reviewed before production writes. Use the current specialization/emission APIs
for meaningful semantic RED before new IR constructors exist: admission must
reject the exact managed source at Specialize, and the emitted scalar function
must have distinct H/result storage and a shared return. A setup/type failure
does not establish that RED. Add exact typed Lower/Own/Verify Loop assertions
with their product change, without a permanent dual-shape predicate or a new
test framework. The whole packet, including the 59-owner ports above, shares
the cumulative 3,300-addition/+1,100-net scalar test ceiling; there is no separate
additional-test allowance.

Require phase tests for Lower origin erasure, single Specialize admission,
unchanged preorder instance IDs, fresh H/P/PRE visibility, independent arities,
zero H, swaps, duplicate occurrences and original-prefix execution on every
iteration. Check exact old source rejection message/help/span and child-first
first-error order. Source managed-TCO/header eligibility stays unchanged.

Own tests check the complete acquire-all-occurrences, retire-H/locals, then
publish-batch order; include one and two aliased loop-local String outputs and
an unrelated PRE String read afterward. Independently constructed malformed
Verify inputs must reject unavailable P/H, wrong edge arity/type, reused or
missing outgoing obligations, live old locals and captured PRE discharge,
including through a LoopMatch arm. No origin preflight or legacy tail fallback
may hide an invalid common loop. Raw managed P acceptance is only a phase
resource proof, not permission for source managed TCO or managed H.

Port every semantic/negative oracle in the enumerated 59-owner closure. Keep
missing/double cleanup, wrong-owner, unavailable-sibling and borrowed-child
faults. Preserve annotated source diagnostics at their actual producer rather
than adding a TCO-origin flag to the raw common runtime verifier. Keep ordinary
declared-result first errors, final Void discards, empty carriers despite outer
reassignment and exact generic/constructor instance order. Review all affected
TCO C individually and require exact C for unaffected programs. Retain the
actual million/0/1/17 output checks without a duplicate stress fixture. Extra
P/owner facts and ARC pairs may affect costs; SOURCE +3% and the original R0
hold still block cost acceptance and production landing.

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
