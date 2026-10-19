# Restricted if and function-top-level propagation

## Status and problem

Historical A/old-base handoff follows; the revised B checkpoint below governs B.

Proposed implementation handoff, based on main
`d82bdf85c4c7375024a1b1a7f2a86aa5e3815b62`. Plan only: no implementation,
compiled job, baseline freeze or sampling is authorized here. Root reviews this
plan before a bounded implementation dispatch. A's direction has root review;
independent plan review precedes its separate plan commit and granular failing
tests. B remains DESIGN ONLY without implementation approval; its typed edges
and cleanup need two independent reviews.
The [roadmap's restricted M2 boundary](ROADMAP.md#m2-the-join) governs placement;
the broader expression-control redesign remains deferred.

Current [expression checking](src/check/expressions.brp):356 rejects IfExpression;
[statement checking](src/check/bodies.brp):763 rejects PropagatingBinding. These
are source-inspected outcomes, not executed reproductions. The reviewed local
annotation and Boolean implementations are separate dependencies: neither
body-checking route is present in this pinned main. Compose their reviewed
changes and the [ordinary-tail preparation](M3_LOOP_PLAN.md#immediate-checkpoint-ordinary-tail-matches)
before implementation. A later authorized implementation may compose these
reviewed predecessor patches in this isolated branch before their individual
landings. Root integrates predecessors first. The composed candidate inherits
neither their validation nor landing permission; preserve every cumulative
ledger debit. Do not duplicate predecessors or recover the unavailable broad
loop draft.

A's prerequisite prose above is historical. Current B below is independent of A,
Boolean admission and held ordinary-tail/M3 work; local annotations/body_types
are already accepted. B does not widen joins to early returns. Preserve all
then-accepted scalar-tail and ownership controls.

## A: if through existing joins

First proposed native input:

```blorp
func main() -> Int:
    var current = 1
    if True:
        current = 7
    else:
        current = 2
    current
```

Expected exit 7, empty stdout/stderr; the False companion exits 2. The checked
join has a Void primary and exactly the existing current BindingId as carrier.
Both edges publish its selected version, including an unchanged false edge when
only the true branch assigns.

### Existing rejection becoming success

A also admits the unchanged six-line
[unsupported/if.brp](test/e2e/fixtures/unsupported/if.brp), SHA256
`5e8e27a3a212d6ed21dac2276c3cedcf2483c96dfcd0caca703c98fe19283704`.
Its [existing registration](test/e2e/test_unsupported_syntax.brp) expects B to
exit 1, write empty stdout and exactly:

```text
blorp_2/test/e2e/fixtures/unsupported/if.brp:3:2: error: `if` is not supported yet
help: match on the Bool condition; `if` arrives with the join milestone
```

C must compile this same input successfully, then run its real main with exit
**1**, empty stdout and empty normal stderr. Distinguish compiler success from
the program's deliberately nonzero result. Reuse this input through existing
run_source_example/native_case helpers; replace only its rejection registration
with the success oracle and retain the other unsupported cases.

Record B-reject to C-success as an explicit outcome change, preserving B's exact
diagnostic evidence. Apply **45,000 allocations/200,000,000 normal instructions**
to C's newly successful compiler invocation, with strict balanced zero leaks.
A +3% ratio against B's rejection is invalid; keep this case in the inventory
under its absolute gate rather than silently excluding it. A's three-new-file /
60-new-source-line fixture allowance counts new fixture files only; retain this
existing input's bytes unless a separate change is reviewed. All new maintained
test/registration lines still debit the 700-gross test ceiling.

### Producer and consumer facts

The foundation's [DesignatedBoolean](src/namespace/builtins.brp):31 is the sole
constructor authority. Reuse the accepted Boolean change's route from
foundation.designated.boolean into ResolutionContext. Check the condition once
against that descriptor's owner using its accepted BooleanOperand diagnostic
site. Never infer Bool from spelling, arity or a same-shaped union.

Resolve ParsedIf's blocks with existing scope, statement and value checking.
Build CheckedJoinArm patterns directly from the descriptor's VariantIds and
publish the existing CheckedForm.Match. Do not manufacture ParsedMatch names
and resolve them again. A root-tail if publishes carried=[] even when an arm
reassigns a mutable prefix: no following statement needs that updated binding.
Prefix statement if retains its required, ordered unique carriers through
carried_bindings, including the unchanged false-edge value. Preserve branch
order, calls, captures and source spans. ElseIf is recursive control at the else branch's
existing permitted position, not a new arbitrary-expression placement.

Retain ValueExpectation's distinction between placement and type:

- Omitted else is allowed in statement roles, inherited statement arms and final
  Void control positions. Every normally completing then-path must be Void;
  statement-only branches synthesize canonical Void.
- A binding annotated Void remains a value position requiring else. An inferred
  Void first branch does not grant omitted-else permission.
- General VoidTail discards do not relax the omitted-else rule. Check its then
  paths with the strict statement-arm rule, including nested controls.
- Preserve annotation expectations before inference. Keep if-versus-match error
  provenance in private checker roles/diagnostics, not a retained IR flag.

Statement/binding/function-tail/arm-tail positions are admitted. The generic
expression planner continues rejecting larger-expression if uses with teaching
help to bind the result first. No new operand workloop, parser desugaring,
specialize/lower/own/verify/emit mechanism or source loop admission is needed.

### Annotated root boundary

For the first slice, reject a source-root if under @tail_recursive after ordinary
body checking and the existing generic-annotation restriction, before nested-tail
analysis. Use ParsedFunction.body's explicit IfExpression; do not retag it as a
legacy CheckedMatchBody to pass TCO analysis.

```blorp
@tail_recursive pure func walk(flag: Bool) -> Int:
    if flag:
        0
    else:
        walk(flag)
func main() -> Int:
    0
```

Proposed exact message: `an if at the root of an @tail_recursive function is not supported yet`.
Help: `write these root branches with match, or remove @tail_recursive`.
Pin the complete ParsedIf.span, bytes [55, 102) in this input. Condition/type/name
errors still precede annotation analysis. Prefix if statements beneath an
otherwise supported root match keep existing scalar checks. Supporting root-if
TCO is a later reviewed rule, not part of A.

## B: frontend Result propagation checkpoint (2026-10-19)

This revised B supersedes the historical flat-edge model below. Plan only: root
and independent review, a separate plan commit and explicit tests-first dispatch
precede implementation. Fixed accepted baseline is
`2aaedc28967f16d9d640256f264e731cf9922d48`; no held feature overlay is a prerequisite.

The user explicitly said: "A 128-statement ?= chain is unrealistic." Accordingly,
only B's artificial 128-chain/flat-C-depth requirement is waived. Test realistic
1/2/5/9/16 chains and record emitted C depth at default toolchain limits, without
new C flags/runtime behavior. This changes no resource, placement or TCO ceiling.

Check the designated Result owner and compatible error type using foundation IDs
and the accepted function return TypeUse, once. For source Result[V,E] and return
Result[R,E], a written binder annotation V supplies complete Result[V,E] context
through existing body_types; otherwise synthesize the RHS normally. Never use R
as V, invent inference holes or add a solver. Underconstrained constructors teach
a binding annotation/typed intermediate. Preserve exact first-error diagnostics.

Consume each source statement once with a suffix index and existing scope/body
resolvers; do not copy suffix arrays or duplicate the remaining body. At each
`name ?= source`, construct one ordinary checked Result-valued join:

```text
Ok(name)  => the remaining function computation, yielding Result[R,E]
Err(error) => construct the returned Result[R,E]'s Err(error)
```

The function returns the outer join value normally. Err is a yield, not a return
inside CheckedJoinArm. Success/error captures use real issued BindingIds and
canonical VariantIds in their own existing arm scopes. Error is private; name is
visible only in the Ok continuation. Specialization selects source constructors
with Result[V,E]'s instance and constructs Err with Result[R,E]'s instance.
Existing join transfer acquires managed payload/results before parent cleanup;
existing Own/Verify handle sibling scope, ancestor lifetime and complete function
return. No new Checked/Concrete statement, Lower/Own/Verify/Emit product, general
continuation framework, text synthesis, fake names or runtime operation.

Keep Result-only function-top-level placement: nested if/match, loop and lambda
propagation remain rejected. Option and annotated-TCO combinations stay rejected;
check ordinary body errors before the explicit annotated-placement diagnostic.
No if/Boolean/ordinary-tail predecessor or general early-return join is required.

First checkpoint: one managed Result witness and exact semantic checker REDs,
then minimum frontend desugaring, short generated-C/native review and the realistic
chain screen. Forecast 160–250 gross production additions/+110–180 net, within
unchanged hard 430/+330; tests <=1,000 gross including one <=40-line fixture.
Prospective fixture limits: 45,000 strict compiler allocations, 200M strict and
normal-min3 instructions, strict balanced-zero target memory and real-main proof.
Before implementation, B selects its first prospective fixed accepted FEATURE
baseline above: +3% allocations and normal-min3 instructions independently per
unchanged shared input, plus all old absolutes. Supporting-host cost rules are
unchanged; no measured HOST pass or retrospective baseline roll is claimed.
The separate [SOURCE fixed-baseline policy](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary)
and all failed histories remain unchanged; that dated decision grants no FEATURE
exemption. No scalar SOURCE ledger transfer or reset funds this checkpoint.
No setup, sampling or compiled call is granted by this plan amendment.

### Historical B scope and flat-edge alternative (not selected)

First scope is the designated Result, at function top level only. Preserve the
parser's existing rejection of nested propagation in if/match, loop and lambda
bodies. Option propagation and annotated-TCO combinations remain unadmitted
until separately reviewed; diagnostics must explain the alternative explicitly.
Local annotations and A do not depend on this model.

### Option source witness census

At this pinned base, a textual census of tracked named functions with explicit
Option return types found:

| Source scope | Option-returning functions | Functions / sites using ?= | Function-top-level functions / sites |
| --- | --- | --- | --- |
| blorp_2/src | 74 | 0 / 0 | 0 / 0 |
| standard_library/src | 150 | 12 / 27 | 4 / 4 |

The four top-level witnesses are [argparse](../standard_library/src/argparse.brp)
get_string:211, get_int:224 and get_float:237, plus
[string.split_once](../standard_library/src/string.brp):1598. The other 23 sites
are nested in eight functions, including bytes.read_int16_be:231 and
argparse.parse_value:416; they cannot justify broader placement. These are
source witnesses, not current Blorp 2 acceptance or new execution evidence.
The census excludes lambdas, inline fixture strings and inferred return types.
The older compiler also has top-level witnesses, e.g.
[frontend_graph_module](../blorp/src/compiler/stage_04_modules/frontend_graph.brp):474-476;
its existing [runtime tests](../blorp/test/test_runtime/test_types/test_question_bind.brp):16-48
cover scalar and String Option propagation.

Option demand therefore exists, while the current Blorp 2 source has no direct
witness. Keep B's first model Result-only. Before expanding it to Option, require
two independent typed-edge/cleanup reviews of the extension and a new bounded
dispatch; source demand alone grants no implementation or placement expansion.

### First Result witness

Proposed native fixture, within 40 source lines:

```blorp
import:
    io: print

func convert(value: Result[Int, String]) -> Result[String, String]:
    first = 1.to_string()
    second = 2.to_string()
    number ?= value
    print(first)
    print(second)
    Ok(number.to_string())

func show(value: Result[String, String]) -> Void:
    match value:
        Ok(text): print(text)
        Err(error): print(error)

func main() -> Int:
    show(convert(Ok(7)))
    original: Result[Int, String] = Err(9.to_string())
    show(convert(original))
    match original:
        Ok(number): print(number.to_string())
        Err(error): print(error)
    0
```

Expected stdout `1\n2\n7\n9\n9\n`, empty stderr, status zero and zero leaked
managed objects. The successful continuation keeps both owned prefixes live at
propagation; failure must clean them without running their prints. Reusing
original proves caller-owned input survives.

### Historical flat-edge typed model (not an implementation requirement)

Current CheckedStatement has InitializeBinding, ReassignBinding and
DiscardExpression. Add one fixed function-prefix operation, schematically:

```blorp
fixed record CheckedPropagation {
    source: CheckedExpr,
    success: CheckedPattern,
    failure: CheckedReturnCase
}

fixed record CheckedReturnCase {
    pattern: CheckedPattern,
    value: CheckedExpr
}
-- CheckedStatement.PropagateFunction(CheckedPropagation)
```

The producer constructs only the canonical Ok(success BindingId) and
Err(private error BindingId) patterns. The source binding is immutable and
visible only after success; the error capture is confined to failure. Its fixed
return value is checked against the declared function return. There is no Yield
or Recur alternative in CheckedReturnCase and no widening of CheckedJoinArm.
These are proposed names/products requiring review before edits, not an already
sealed API.

One foundation DesignatedResult supplies declaration identities. Body checking
receives that descriptor and the already accepted function return TypeUse; do
not repeatedly rejoin signatures. Honor local annotation context through the
existing inference machinery. Validate nominal Result identity and error-type
compatibility, not shape or names. Preserve established annotation/name/type
diagnostic order; ordinary body checking precedes new TCO placement restrictions.

Distinguish source Result[V,E] from returned Result[R,E]. In the fixture, source
is Result[Int,String], output Result[String,String]. Specialization translates
failure pattern Err with the **source** instance, and ConstructVariant(Err, ...)
with the **target** instance. Reusing the source concrete VariantInstanceId for
the returned value is incorrect even when their numeric tags coincide. Publish
these established identities and types once; retain exact generic instance-ID
tests and reject mismatched error types with source-anchored message/help/span.

Lowering evaluates source once. Its step introduces one success value in the
parent interval; private failure captures/definitions follow the parent interval
as existing branch completion does. The failure block ends in a fixed function
result ValueId, never a join yield. Success uses the existing payload projection
fact with its canonical VariantFieldInstanceId. No continuation/destination mode,
CPS nesting, new registry or general return framework is required.

Own publishes explicit operations for each edge. Success obtains a valid payload
obligation before source-parent retirement; use existing projection/acquisition
rules. Failure constructs/acquires the returned Result before dropping every
remaining live function-local obligation, including prior join outputs and
ancestors of borrowed children. Never discharge caller-owned ABI obligations.
Reuse ReturnTransfer; do not reuse a join's keep-enclosing policy for this exit.

Verify independently checks failure as complete function discharge, success as
normal parent continuation, and scope/arity/type/owner availability. Raw nested
propagation is rejected explicitly. Emit a flat failure test with cleanup and
return, then success projection and the following prefix. Never emit another
fixture main or infer a return destination from C shape. Work must be proportional
to actual edge/cleanup output; no repeated whole-program walk or hidden repair.

Initially reject PropagateFunction in an annotated function before TCO conversion,
after ordinary checking. Do not guess that its failure means Loop Break. Root
must approve the exact diagnostic/placement rule and owned edge product before
B's implementation.

## Historical shared regions and integration ownership

These anchors describe the original A/flat-edge handoff. Current B has no new
downstream model or held-predecessor dependency; preserve current accepted code
and integrate its frontend edits by symbols, not old whole-file replacement.

| Region | Existing writer/conflict | Coordination rule |
| --- | --- | --- |
| bodies:380 resolve_match; 852 resolve_body MatchBody | Ordinary-tail prep replaces resolver/annotated adapter | Land prep first; retain its empty carriers, local builder and unchanged TCO order; never restore resolve_arms/ArmProgress |
| bodies:456 ValueExpectation; 513 resolve_value; 566 resolve_join; 614 resolve_join_arms | Annotation expectations and if arm roles meet here | Preserve private rationale and exact declared-result sites; no independent expression recut |
| bodies:745 resolve_statements; 790 resolve_assignment | Reviewed annotations; B adds prefix step | Compose annotations first; preserve reassignment/error precedence and one checked statement per source statement |
| callables:195 ResolutionContext; check:65 check_program; bodies:932 check_functions | Boolean descriptor and declared-return construction | Consume the accepted descriptor patch once; one authority per fact |
| recursion:115 statement_values; 239 check_execution | Ordinary prep deliberately leaves these unchanged | A/B add explicit source-placement rejection; retain scalar/generic/no-self diagnostics |
| model:212 CheckedStatement; 537 append_statement_calls | B's statement/call facts | Visit source and failure value in evaluation order; no source spelling recovery |
| specialize statement/type/translation visitors; lower:626 lower_statements and block completion | B adds one step, A reuses Match | Preserve instance order, parent success/private failure intervals and read multiplicity |
| own:843 insert_steps/1024 insert_block; verify:1947 verify_return/2596 verify_function | B owns failure discharge | Agree the typed edge first, then implement insertion and independent negatives together |
| emit:2054 append_function/2222 function_blocks | B's fixed failure block | Extend operation/inventory walks once; retain ordinary-prep C/ARC oracles |

The ordinary writer also updates three stale model comments without data-shape
changes. Retain them. New if/propagation suites use separate files rather than
competing edits to its test_join packet. No shared mutable implementation files;
root assigns integration and reviews the complete composed patch. Composition
and preparatory landings never reset the production/test/fixture ledgers.

## Granular TDD and acceptance

Start with normal Blorp TestSuites; no Python tests or alternate native entrypoint.
Every diagnostic callback pins kind, full message/help and exact source span.

| Slice | First RED and subsequent controls | Deliberate fault proving the oracle |
| --- | --- | --- |
| A | first fixture; canonical constructor IDs; wrong Int/same-shaped union condition; branch effect order | Swap true/false labels; observe only the selected-branch test fail |
| A | omitted else in statement/inherited arms/final Void; reject non-Void then-path and Void-annotated binding; else-if | Let VoidTail discard an Int omitted-else arm; the exact rejection test must fail |
| A | typed annotation/declared return first errors; prefix statement's ordered unique carriers with unchanged false edge; root-tail mutable-prefix reassignment asserts join.carried.is_empty(); root-TCO rejection | Omit the prefix statement's false carrier; phase edge and native False control fail. Adding a root-tail carrier fails its exact empty-carriers assertion |
| B | source/target Result instances differ; annotation context; mismatched error type; source evaluated once | Reuse source Err instance for target; exact layout/instance oracle fails |
| B | direct Own output order and independently malformed Verify IR for missing/double cleanup, wrong owner, borrowed child and sibling visibility | Drop the result parent before acquisition; the isolated verifier negative fails for its exact reason |
| B | two live owned prefixes, successful continuation, failure exit, caller alias survives; existing parser rejections | Omit one failure-path drop; real-main leak control fails |

Keep all then-accepted checker/ARC/C and scalar-tail controls. Held prep/common-loop
oracles are not B prerequisites or inherited validation.
After root grants a lane and pins host/std inputs, the narrow command is:

```bash
env -u BLORP_CC -u BLORP_LEAK_CHECK -u BLORP_MEMORY_STATS \
  -u BLORP2_COMPILER -u BLORP_2_INSTRUCTION_CHECK \
  /Users/keithphilpott/CLionProjects/blorp/bin/blorp test \
  --std-dir /Users/keithphilpott/CLionProjects/blorp/standard_library/src \
  --suite --timeout 180 blorp_2/test/unit/test_check/test_if.brp
```

Then run the corresponding checker, specialize/lower, own and verify suites;
new propagation suite is test_check/test_propagation.brp. Finish with normal
`make -C blorp_2 test` only after root supplies/verifies the intended repository
host in that checkout. Its e2e target builds the compiler once and supplies it
explicitly. Review affected C; require exact C for unaffected inputs. Record
A's 16/32/64/128 flat-control scaling and default-toolchain C depth; revised B uses
its user-approved 1/2/5/9/16 screen instead. Never raise a
compiler nesting limit to hide a failed structural gate. None of these jobs is
authorized by this plan alone. Update the README's supported subset and examples
with implementation; the grammar already parses these forms and gains no new
expression placement.

## Proposed screens and cost ceilings

These are proposed stops for review. Effective allowance is the lesser of each
screen and the remaining root-assigned cumulative ledger; they are not separate
worker budgets. Report gross additions, deletions and net separately, including
replacements, tests and fixtures. No deletion credit against gross additions,
compressed formatting, coverage removal or reset after a preparatory landing.

| Slice | Unmeasured production forecast | Proposed production stop | Tests/fixtures stop |
| --- | --- | --- | --- |
| A, after Boolean/annotation composition | 130–210 gross, +90–160 net | 210 gross and +160 net | 700 gross tests including at most 3 new fixture files/60 new source lines |
| B, revised frontend checkpoint | 160–250 gross, +110–180 net | 430 gross and +330 net | 1,000 gross tests including one managed fixture/40 source lines |

The maxima are not additive permission. Current B uses the checkpoint above,
not A's historical predecessor/ledger route or the unselected four-product model.
Keep scalar SOURCE accounting separate; no transfer, reset or hidden debit.

Propose at most +3% allocations and normal min3 retired instructions per unchanged
shared owned input for the composed candidate, against one approved reference,
not a fresh +3% per landing. Zero leaked target objects and unchanged ABI/value/IO
are hard correctness requirements. Until self-compilation works these are source
proxies. The existing original R0/checkpoint policy and unresolved SOURCE hold
remain unwaived: no corpus/epoch freeze, sampling or production landing until
root resolves that policy.

A's proposed absolute new-fixture ceilings are **45,000 allocations and
200,000,000 normal retired instructions per fixture**, using the established
compiler-invocation e2e cost role and normal min3 instruction rule. At most three
new fixture files/60 source lines fit inside A's 700 gross test additions; the
same absolute cost ceilings cover the existing rejection-to-success input. Target
runtime independently requires strict zero leaks and balanced managed
allocation/release counts from the actual emitted target memory runtime. Compose
the reviewed [memory-accounting predecessor](PILOT_MEMORY_ACCOUNTING_PLAN.md)
for native proof when needed; its validation/acceptance is not inherited.
Supporting-host totals or a diagnostic build flag alone cannot establish target
balance. Verify the target's strict report and leak-fault oracle on the composed
candidate. Source shape/LOC, compiler costs and target runtime
are distinct acceptance evidence; none substitutes for another. These proposed
numbers authorize no cost setup or sampling and waive no original R0 gate.
B's prospective 45,000 allocations/200M strict and normal-min3 fixture ceilings
are specified in its revised checkpoint; no existing limit is changed.

## Subsequent common-loop forecast and handback

After ordinary-tail lands, start from accepted source and its actual ledger.
The unavailable 774-line draft is a candidate to replace, not a required seed.
Do not count its disappearance as retirement. An initial conservative scalar
forecast is still approximately 1,050–1,250 gross/+220–420 net production,
inclusive of accepted ordinary-prep debits, with roughly 1,200–1,750 gross tests.
This is an uncertainty range, not proof of fit: its upper end breaches the
unchanged 1,150/+350/1,600 caps. No common-loop implementation dispatch follows
until a bounded accepted-source producer/consumer inventory and typed ownership
proposal reduce that upper trajectory within the remaining ledger.

That checkpoint must settle header/result/PRE intervals, acquire every outgoing
loop occurrence before H/local retirement, and test duplicated loop-local String
P, a single local output and independent PRE live-after-loop. Later managed
String while retains its separate existing 750-gross/+600-net and 1,600-test
stops, at most three fixtures/120 source lines; it cannot fund scalar growth.
Source List walks and six ranges remain subsequent reviewed migrations after
working loop ownership and required ordering APIs; they are not admitted here.

Hand back branch/base, one exact patch/hash, cumulative counts and forecast,
root/independent review verdicts, authorized RED/GREEN/mutation/native/C evidence,
and unresolved decisions. Stop for unclear return/owner scope, changed producer
authority, a new framework or whole-program scan, host defect or a ceiling breach.
Root integrates. This document needs link/path/whitespace review, not compiled
gates; it grants no implementation or cost execution.
