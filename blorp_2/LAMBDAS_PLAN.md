# Pure known-callee lambdas and immutable captures

Plan base: accepted `eca1f723cab0ef87c498b81f124edf51546765fc`, 2026-10-19.
This plan owns the two remaining callable increments after
[named callbacks](NAMED_CALLABLES_PLAN.md). Root coordinates implementation,
serial compiled leases, two reviews per slice and publication. Commit this plan
before production changes; plan acceptance does not establish feature readiness.
The original drafts and independent review remain under the ignored
`build/bootstrap-evidence/lambda-plan-2026-10-19/` evidence directory.

## Authority, current witnesses and exclusions

Build on accepted named/forwarded pure callbacks and direct specialization.
No function pointers, escaping/stored callable values, general closure ABI,
traits, callback capture, higher-order lambda parameters or HOF removal.
Do not infer purity: plain `func` stays impure; only written `pure func` qualifies.
Existing placement/purity/tail restrictions and lambda propagation rejection stay.

Current anchors under `blorp_2/src/`:

| Producer/consumer | Authority |
| --- | --- |
| Parser | `utils/syntax.brp:486–505`: annotated/discard parameters, InlineBody/BlockBody |
| Expressions | `check/expressions.brp:405,1423`: current rejection; `:323,608,624,933`: argument/work/slot authority |
| Four external entries | `check/bodies.brp:319,527,529,553`: scrutinee, synthesized/checked value, statement value |
| Bodies | `check/bodies.brp:616,877,1009,1070`: joins, root body, recursion, Void discard |
| Model/scope | `check/model.brp:118,144,188,348`; `check/scope.brp:18,49,58`; `check/errors.brp:15` |
| Finite instances | `check/recursion.brp:390`: checked potential dependency edges |
| Specialize | `specialize/specialize.brp:61,414,886,2035,2200,2719`: keys/layouts/choices/translation |
| ABI order | `lower/lower.brp:914`; `verify/verify.brp:1161`: binding ordinals versus signature order |

Since e706, eca1 removes redundant expression purity parameters. Preserve one
active purity authority in ResolutionContext.caller; do not reintroduce them.
[NAMED_CALLABLES_PLAN.md](NAMED_CALLABLES_PLAN.md) owns named semantics and shared
resource authority; [OPTION_RESULT_PLAN.md](OPTION_RESULT_PLAN.md) owns the
required callback helper APIs. Neither helper activation nor source migration
belongs to these language increments.

The retained lambda-requirements packet found 59 pure lambdas, 47 inline/12 block,
21 capturing/54 resolved edges. Blocks: nine return annotations, three complete
Bool contexts. Refresh changed-file correspondence before implementation; the
old 47-total estimate is obsolete. Witnesses include typed noncapture
`main.brp:85`, `specialize/specialize.brp:200`, nested immediate/grandparent capture
`check/render.brp:974–978`, and a no-shadow conflict in `check/inference.brp:902`.
Preserve no-shadowing; source parameter renaming is a later bounded slice.
Surrounding if/not/qualified-pattern/loop gaps are not implicitly admitted.

## Single identities and sealed products

Proposed sketches describe types, not new source syntax:

```blorp
opaque LambdaId = Int                  -- globally dense, separately issued
BodyOwner = DeclaredBody(FunctionId) | LambdaBody(LambdaId)
ScopedBindingId = { owner: BodyOwner, binding: BindingId }
CheckedLambda = { root: FunctionId, parameters: List[TypeUse], return_type: TypeUse,
                  bindings, captures, statements, body: CheckedBody }
CheckedBodies = { functions: List[CheckedFunction], lambdas: List[CheckedLambda] }
```

CheckedFunctions gets exactly one `lambdas` list; LambdaId is its position.
CheckedFunction gets no lambda field; no per-root list/range/lookup cache exists.
Each lambda row records its genuine root FunctionId once, for module/privacy
and genuine declaration-owned rigid parameters. No fabricated namespace IDs.
It owns no new generic parameters: specialization applies the root's genuine
type substitution to its parameters, return and capture types. Pure admission
is invariant in this lambda product, not another mutable purity flag.
Local BindingId stays dense within BodyOwner. Scope bindings and BindingSite
retain/read ScopedBindingId, rather than attaching the current root to a
foreign local ordinal. Capture positions are interpreted through the owning
lambda row, with one ordered capture list as environment field authority.
Diagnostic facts retain owner, name and span; rendering a checking failure must
not require a lambda inventory that checking has not yet sealed.

ResolutionContext keeps `root_function: FunctionId` with root module/signature/
rigid facts, while its active caller becomes `{body: BodyOwner, purity}`.
The transient root fact initializes each sealed row's root once; no second
published index is retained. Enter a lambda with LambdaBody(id)
and Pure; restore caller on finish. A pure lambda inside an impure function
still rejects an impure call. A call to an annotated enclosing function inside
a lambda is an ordinary call from another body, never rewritten as the outer
RecurWith or counted as its direct self edge. Existing named-tail restrictions
still apply where their actual declared-body identity matches.

Private construction state `LambdaRows = List[Option[CheckedLambda]]` reserves
one None at admission; its length issues LambdaId exactly once. Deferred work
reuses that ID. Fill its row after all types/body facts complete; seal only when
every slot is Some. Partial rows and inference variables never cross Check.
Progress flows from one declared function into the next. `resolve_functions`
returns CheckedBodies; `check_program` consumes it to construct CheckedFunctions.
No global mutation, external registry or parallel accepted inventory.

## Exact entry/result and body boundary

Shared data-only result types belong in existing check/model; they import
neither Scope, bodies nor expressions. The private construction-state type may
be checker-visible there; only complete rows enter CheckedFunctions.

```blorp
CheckedValueResult = { value: CheckedExpr, lambdas: LambdaRows }
ResolvedLambdaBody = { bindings, statements, body: CheckedBody, lambdas: LambdaRows }

synthesize_value(scope: List[ScopedValue], written: ValueExpression,
    constructor_type: Option[TypeRef], context: ResolutionContext,
    lambdas: LambdaRows, resolve_block)
    -> Result[CheckedValueResult, CheckError]
check_value(scope: List[ScopedValue], written: ValueExpression,
    expected: TypeRef, site: ExpectedTypeSite, context: ResolutionContext,
    lambdas: LambdaRows, resolve_block)
    -> Result[CheckedValueResult, CheckError]

resolve_lambda_block(scope: List[ScopedValue],
    parameter_bindings: List[BindingDefinition], block: ParsedBlock,
    result: TypeUse, context: ResolutionContext, lambdas: LambdaRows)
    -> Result[ResolvedLambdaBody, CheckError]
```

`scope` is List[ScopedValue], parameter_bindings is List[BindingDefinition],
context is ResolutionContext, and result contains a complete TypeRef. The first
two entries take a pure callback with exactly the last signature. This is one
specific dependency, not a service abstraction or generic context carrier.
Bodies implements the named resolver with the same statement/match/join/Void
algorithms; it has no resolver parameter itself. Bodies passes that named
function at the four expression entries; expressions forwards the received
resolver unchanged. No convenience lambda captures it, no self-referential
callback type, fabricated AcceptedFunction or copied body checker.

Thread returned lambdas through start_match's scrutinee (319), resolve_value's
two branches (527/529), statement_value (553), ResolvedValue/ResolvedStatements/
ResolvedBody and arm/join progress. Each subsequent operand, statement, arm and
declared function receives the latest rows; never initialize another inventory.
Existing CheckProgram public reader remains unchanged. Recursion, model call
walks, Specialize preparation/translation and render consume the new owner/row
facts; Lower receives ordinary concrete products only.

## Noncapture inference contract

Lambda literals are admitted only as written arguments to expected pure callable
parameters. General expression/storage/return attempts keep a teaching rejection;
this does not promise general callable values. Slice one rejects all data
captures early; slice two rejects mutable/callable captures at resolved uses.

Written parameter annotations constrain caller slots. Otherwise input types must
be complete after ordinary argument constraints; enclosing rigids are complete,
unbound call-local variables are not. Unknown inputs ask for an annotation;
body operations never invent an input type. Callback-before-data remains legal:
ordinary data can solve T before its earlier lambda body is entered.

Extend existing pending-call work with a pending lambda operand retaining its
reserved ID and expected callable hint. Solve available ordinary constraints,
run newly ready bodies once, and repeat only while constraints make progress.
On no progress, diagnose the first unresolved lambda input in written order.
Use existing slots/work/operands, never another solver. Inline return constraints
share those slots, allowing simultaneous T/U and later sibling evidence. A local
pending inline-body value may survive until final freeze; publish its complete
CheckedLambda row only after shared types settle.

A typed lambda-finish frame saves/restores active body/scope/bindings/capture
accumulator around child work. Do not attach a full context to every old action.
Blocks use a written return annotation or already complete expected return;
partial Result/Option contexts require an explicit annotation. Block resolver
therefore needs no inference-slot API, guessed nominal head or pending join IR.
Recursion analysis precedes canonical Void discard as in existing body checking.

A written return annotation has two consumers: constrain the original caller
result term, and pass the written type as the lambda body's expected type. A
bare record literal needs that nominal hint during planning; a solved bare
call variable does not establish it. Retain the written type in the existing
LambdaAdmission.result rather than recovering record identity from slots or
adding another hint carrier.

## Immutable capture and erasure contract

Resolve outer data by ScopedBindingId, deduplicate first-use identities, and
retain accepted type/span for diagnostics. Two aliases of one String remain two
field occurrences. A lambda read becomes ReadCapture(field position) owned by
its lambda row. Local mutation stays legal; outer mutable/callable capture rejects
even if its layout would be scalar or empty.

Finish a nested child by restoring its parent FIRST; build child capture operands
through the restored parent's identity lookup. An ancestor read then interns a
parent capture, including a grandparent used only for child creation. Preserve
updates to this restored accumulator; do not overwrite them with a saved copy.

Add precise declared/lambda origins to existing function instance requests and
capture-environment/declared origins to existing record preparation/sealing.
Lambda code/layout key uses site and concrete enclosing ordinary type arguments,
never runtime capture values. Excluding parent callable choices is valid only
while captured callables/higher-order lambda inputs reject. Real ordered choices
continue distinguishing actual declared callees. No fake RecordId, new layout
engine/cache or duplicated signature authority.

Choose existing ordinary managed-record representation for every nonempty capture
environment in this increment; no new scalar-inline optimization is required.
Noncapture has no record, allocation or fake Void parameter. A capture of Void
still denotes a real capture field/environment, not noncapture.

Lambda body ABI is **environment first**, then ordinary lambda parameters;
noncapture has only ordinary parameters. A higher-order function's ABI is
different: data consumes one slot, named/noncapture consumes zero, capturing
callback consumes one environment at that written argument position. Construct
environment operands there in source evaluation order; merge validated callable
positions with data operands, never infer positions from spelling/types.
Forwarding passes the existing environment; invocation is a normal direct call.
ReadCapture becomes concrete record projection before Concrete publication.
Own/Verify/Emit get no lambda/capture operations and no new runtime ABI.

Keep dense checked BindingIds; remap ParameterBinding runtime positions and add
real environment bindings. Required `(x, capturing_f, y)` oracle: old data binding
IDs remain unchanged, appended env maps to runtime parameter1, signature is
`[x, env, y]`. Lower's current binding-list walk would emit 0,2,1 and Verify1164
correctly rejects it. Build a temporary local runtime-ordinal-to-binding inversion
in Lower, emit parameters 0,1,2, and populate the existing BindingId-indexed value
vector. Discard the inversion; do not weaken Verify or renumber all old bindings.
Preserve e706 definition-only call anchors.

Normal record construction acquires each managed field occurrence. Returning a
captured String acquires its own owner before env retirement; forwarded aliases
remain independent. Existing aggregate/call ownership is authoritative.
Visit every sealed lambda body's potential calls in existing finite-instantiation
analysis, even ignored/nested lambdas, using root's genuine rigid identities.
Creation is not execution, and no new dependency graph framework is proposed.

## Atomic slices, proposed stops and evidence

| Slice | Production ADD / net stop | Nonfixture tests ADD / net stop |
| --- | ---: | ---: |
| 1: noncapture inline + bounded blocks, full direct path | 900 / +700 | 700 / +700 |
| 2: immutable envs, forwarding, nesting and ordinal map | 825 / +650 | 950 / +950 |
| Combined | 1,525 / +1,200 | 1,650 / +1,650 |

These are hard implementation stops for the separately reviewed slices.
The noncapturing production allowance was revised after an early checkpoint of
401 additions / 97 deletions. Two code audits found necessary body identities
and global row threading, with no large duplicate architecture. Required caller
inference scheduling and completion were underestimated: complete scope is about
806 additions / +610 net, with a plausible 760–865 range. Reassess at 765 gross
or 595 net before further production; these are 85% of the revised phase stops.
Phase maxima are not reserved or additive allowances: combined 1,525 / +1,200
remains independently binding. At the 806 / +610 point, 719 / +590 remains.
Captures forecast 565–745 / +430–580, so upper gross exceeds that remainder by
26; complete fit is unproven. Before capture implementation, reforecast its
complete path against the actual accepted noncapturing ledger, using the same
physical-diff accounting boundary and accounting true overlap once. Stop if
either the capture phase cap or remaining combined gross/net cannot fit. No
automatic transfer, cap increase, scope reduction, coverage cut, compression or
new solver is allowed. Mandatory test ports add 39 lines and remove 27 across
six owners, preserving 19 callbacks; complete tests forecast 670, below 700.
Original M7 B, 8% hard / 6% reassessment, fixture/API/report caps and all other
acceptance obligations remain fixed. LOC feasibility does not imply cost acceptance.
At 85% of either gross/net slice stop, review actual remaining work before more
implementation. Owner forecast remains model/scope/errors/render180–240,
expressions/inference420–520, bodies/publication180–240, recursion40–70,
Specialize320–420, Lower20–35; Own/Verify/Emit production zero expected.
All mechanical constructor/observer ports count. No compression/deleted coverage.
Fixtures are separate: at most three/150 physical lines combined, not charged
again to nonfixture tests. Active API/reference docs <=100 additions, retained
final evidence <=120 physical lines, plan <=350 physical lines, counted separately.
Later source renames/import/helper integration needs a separate frozen slice.

Minimal ordinary-main witness, with normal library imports:

```blorp
import:
    int as IntOps

pure func apply_first[T, U](f: pure (T) -> U, value: T) -> U:
    f(value)
func main() -> Int:
    apply_first(pure func(number): IntOps.add(number, 1), 7)

pure func produce() -> String:
    prefix = 42.to_string()
    apply_first(pure func(_: Int) -> String: prefix, 0)
```

First program exits 8; managed caller prints produce after prefix/env die.
Extend three fixtures with UTF8/NUL, old aliases, unused result, repeated
forwarding and a nested outer lambda whose only grandparent use creates inner.
Each proposed fixture uses existing generic LIMITS: 150,000 allocations/600M
instructions on one strict native compile, unless a smaller prospective bound
is separately justified before writes; no existing limit changes. Argv cases
reuse the ordinary real-main binary.

Tests: distinct sites/equal local ordinals, deferred-ID stability, typed first
diagnostics, callback-before-data and simultaneous T/U, complete Bool/annotated
Result blocks and partial-return rejection, pure lambda in impure root rejecting
impure calls, enclosing annotated self call not outer RecurWith, no-shadowing,
mutable/callable capture, noenv noncapture, interleaved runtime slots, grandparent
propagation, aliases and ignored-env cleanup, ignored-lambda generic growth.
Pin env construction relative to ordinary impure argument calls at phase level.
Independent public Own/Verify faults remove actual captured-return acquisition or
repeat discharge; retain exact failure and restored green. Emit proves direct
ABI/evaluation order. No production tracing, alternate main, C rewrite or new runner.

Retain SAME original M7 B `5c3e9f3ddc1a51290d1fb0dbbb7e90eb84039586`.
Independent cumulative 8% hard: allocations 26,356,379 and normal-min3 instructions
48,530,311,547. Stop at 6%: 25,868,299 or 47,631,602,075 for remaining-work/cost review.
No reset/stacking or assumed lambda headroom; old 3% RED remains historical.
Freeze full B/C source/library/canonical paths and original schema1 construction
proxy/host/STD/tool roles before samples. Normal/diagnostic C agree per variant;
unaffected noncallable fixture C stays exact. No invented B success for new inputs.
Measure the first complete managed-capture checkpoint before extended coverage.
Harness-boundary changes are separate epochs, never retroactive passes.

### Prospective supplemental old-B/current-C cost comparison

Review and publish this amendment, then obtain an explicit finite cost grant.
This independent new-path matched comparison leaves original B and raw samples
untouched: 24,404,055 allocations; 44,935,473,655 normal-min3 instructions.
It gives no retroactive old-role pass or changed-STD-path equivalence credit.
Use original normal6852e1c6/diagnostica362b0df and the same pinned timer/tool roles.
Freeze all B/C source41 bytes/modes, libraries, physical paths, argv/environment,
tools and output/report endpoints before calls; source compatibility stays exact.
ROOT means the persistent /Users/keithphilpott/CLionProjects/blorp checkout.
Choose only ROOT's preserved-host01/standard_library archive, exact91 bytes/modes,
under build/bootstrap-evidence/host-string-equality-2026-10-19/; no links/fallback.
Never overwrite current ROOTSTD; ROOTfbb/currentSTD remains a separate functional role.
Use new ROOT/build/bootstrap-evidence/lambda-supplemental-cost01/ as the endpoint:
active/blorp_2/src/main.brp is the SAME physical source argument for both variants;
active/compiler.c is the SAME physical output pathname on every call.
Copy immutable B41, then frozen current C41 serially into that isolated active tree;
verify exact members/hashes/modes each time; never modify either frozen payload.
Per variant run one diagnostic and three positive normal instruction samples,
quiet and serial in ROOT's exclusive compiled lane; retain normal-min3.
Before each next call preserve raw C/stdout/stderr/time/report and exact command
under a fresh variant/run directory; require diagnostic/normal C exact per variant.
Read exactly one schema1 artifact_construction_complete cumulative total_allocations;
never use end-process totals. Finally restore and verify frozen current C41 there.
For each metric require C <= min(original absolute 8% ceiling, floor(Bsup*108/100));
reassess at original 6% threshold or floor(Bsup*106/100)+1, where Bsup is new B.
No subtraction, offsets, automatic B resampling, reset or stacked credit.

### Prospective C-only instruction characterization

STOP5's 26,525,323 allocations remain HARD FAIL; no acceptance or waiver.
After two reviews, publish this amendment and obtain a new finite serial START.
Run only frozen commands06/07/08: C normal1/2/3, once each, in that order.
Keep f798 source, producers, old STD91, parent environment and physical paths exact.
No setup compilation, new B, diagnostic, resampling, repair or source change.
Preserve each raw run before clearing shared outputs; require C exact to STOP5.
Record three positive instruction values/min3. Budget misses remain FAIL;
other failures STOP immediately. Restore frozen C41 and return the lane.
Allocation HARD FAIL binds regardless of instructions; no numerical waiver.

Per-slice acceptance: semantic RED, owner GREEN, source41 parse, generated C,
effective faults/restoration, full component/native gates with strict zero and
sanitizers, cumulative costs/LOC inside stops, two final independent reviews.
Stop on setup ambiguity, new mechanism need, forecast excess or failed gate.
Report actual self-compilation first error; leaf acceptance is not M8 proof.
