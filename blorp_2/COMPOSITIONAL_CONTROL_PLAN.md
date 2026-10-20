# M2.2: compositional blocks and if

**Bootstrap scope update.** This is the future general-expression design. The
active [source plan](BOOTSTRAP_SOURCE_PLAN.md) lifts expression-child controls
into preceding bindings and retains restricted body control, outer-variable
joins and managed loops. General expression inference and workloop relocation
below are deferred; the existing join/ownership contracts remain authoritative.

The logical-operator candidate used for the historical anchors below is paused;
[ordinary Boolean functions](BOOL_FUNCTIONS_PLAN.md) are the active direction.
This general-expression design grants no implementation or cost acceptance.
Resolve named declarations against the accepted source rather than relying
on scratch files or old line numbers. The accepted quality APIs, including
naming and private-type rules, remain prerequisites. Constants and recursive
data work stay separate.

## Problem, examples and semantics

The parser already represents control expressions in child positions, including
call arguments and blocks. Checking only handles a bare value-position match.
Adding a bare-if exception would repeat that incomplete boundary.

First if fixture, compiled and run through ordinary main:

```blorp
pure func identity[T](value: T) -> T:
    value

pure func choose(ready: Bool) -> Int:
    identity(
        if ready:
            23
        else:
            17
    )

func main() -> Int:
    choose(True)
```

Expected exit 23, empty stdout/stderr; False companion exits 17. This is the
grammar-correct multiline form of `consume(if ready: 23 else: 17)`, not new
single-line syntax. Before changing if, the compositional-match foundation gets
the analogous fixture with `match ready` as identity's argument.

An arm may have its existing statement prefix and a nested control value:

```blorp
pure func choose(ready: Bool) -> Int:
    identity(
        if ready:
            chosen = 23
            match ready:
                True: chosen
                False: 19
        else:
            chosen = 17
            chosen
    )
```

Both chosen declarations have the same NameId but distinct function-owned
BindingIds; neither enters its sibling's or caller's scope. Conditions and every
written branch are checked statically; runtime evaluates the condition once and
only the chosen branch. Else-if uses the parser's existing ElseIf structure.
Generic result context, including `identity(if ... String ...)`, reaches final
arm values through the same pending inference session.

With else, value branches need a value and agree under an explicit expected type
or their first value's type. A nonfinal statement requires Void branches. A Void
function tail retains the existing match rule: fully check branch values, then
discard them during Void normalization. Without else, the then block must be
Void, with an explicit generated False→Void arm; it cannot supply a non-Void
value. A Void use is legal; IfNeedsElse applies when the consumer requires a
non-Void result, while an untyped no-else expression synthesizes Void. This matches
`docs/GUIDE.md` Control Flow and the existing compiler's
`infer_if_expr`/`test_if_without_else_requires_void_then_branch` precedent.

## Existing boundary and smallest recut

Actual source before this change:

```blorp
-- bodies.brp:546
private fixed record ResolvedValue {
    value: CheckedExpr,
    bindings: List[BindingDefinition]
}

-- expressions.brp:1255 (check_value has the same CheckedExpr-only result)
pure func synthesize_value(scope: List[LocalBinding], body: ValueExpression,
    constructor_type: Option[TypeRef], context: ResolutionContext
) -> Result[CheckedExpr, CheckError]:
    elaborate_value(context.caller.purity, scope, body, constructor_type, None, context)
```

`bodies.brp:573–610` diverts only bare_match to resolve_join; `plan_base` at
`expressions.brp:351–381` rejects IfExpression and MatchExpression. Nested values
therefore cannot return new binding facts. Freezing each nested arm separately
would also lose surrounding generic constraints. `start_match` at bodies:374
and `resolve_arm_prefix` at 421 currently rely on complete scrutinee/prefix types.

Dependency search finds exactly one production expressions importer: bodies.
Move the existing work loop into that owner, not all expressions into a giant
module and not another block-checker hierarchy:

| Mechanical move into bodies | Current source |
| --- | --- |
| OperandRange, ExpressionWork, ListProgress, ResultInferenceState, stack/operand helpers and argument_work | expressions:239–350 |
| placed_arguments/readiness and finish_pending_call, solely used by the loop | expressions:489–549 |
| elaborate_value | expressions:550–1002 |
| Boolean pending construction/constraint helpers, solely used by the loop | expressions:1020–1075 |
| synthesize_value/check_value entries | expressions:1255–1273 |

About 685 existing lines move. Preserve the two entry signatures and behavior
in this preparation; they become private to bodies because no other production
consumer exists. Expressions remains pure term planning/publication, importing
no bodies. Bodies imports its narrow typed interface. Newly public helpers:
resolve_postfixes, plan_expression, pending_receiver_contract, pending_field,
freeze_pending_value. Newly public types: ResolvedPostfix, PendingPostfix,
ExpressionPlan. Their sole consumer is bodies' moved loop; declare these complete
types public so accepted private-type rules apply. Existing LocalBinding,
lookup_binding and binding_site remain unchanged. No other exports are needed.
Scope/pattern admission remains pure leaf helpers already in bodies; extracting
new modules is unnecessary. Recursion/signatures/constructors/inference keep their
current roles. Review the actual dependency/visibility diff before accepting prep.

## Ownership, lifetime and complete contracts

| Fact | Owner, lifetime and consumers |
| --- | --- |
| Canonical Bool variants | Accepted foundation, whole compilation; condition constraint and generated arm labels borrow IDs. |
| Signatures, types, namespace visibility | Existing frozen authorities; ordinary call/constructor/pattern helpers consume them once. |
| Binding identity and accepted definitions | Bodies, one append-only local builder for a function; append after accepted initializer/capture, return the complete advanced vector, freeze with CheckedFunction. Never reserve by spelling or snapshot it per arm. |
| Lexical visibility | Explicit scope attached to scheduled expression/block work; sibling tasks retain the original scope. Scope may share immutable prefixes; the function binding vector never implies visibility. |
| Inference variables and pending final arm values | Existing local work loop, one enclosing expression session; discarded after complete freeze or one typed error. No inference state reaches CheckedProgram. |
| Prefix statements | Same complete initializer boundaries as today, produced by the same engine; CheckedStatements feed pending arms. No backward inference through an already published local binding. |
| Control edges, ownership and destruction | Existing CheckedJoin/CheckedMatchBody → specialization/lower → own/verify/emit. No new checked or downstream control/runtime form. |

After mechanical prep, the internal entry carries the facts the consumer needs:

```blorp
-- Signature sketch; existing ValueExpectation retains its distinct modes.
private pure func elaborate_value(
    block: ResolvedStatements,
    written: ValueExpression,
    expectation: ValueExpectation,
    position: ControlPosition,
    context: ResolutionContext,
) -> Result[ResolvedValue, CheckError]
```

Its work/operand/slot builders remain local. EnterExpression additionally carries
its lexical scope and explicit control position. A child that adds bindings returns the advanced function
builder, while callers keep their own scope. Update start_match to carry the
scrutinee's advanced bindings before allocating captures: nested controls in a
scrutinee must not reuse their IDs. Remove the bare_match bypass in the complete
compositional-match slice; every child position uses this one owner.

Add typed work for entering a control and completing its arm blocks. An arm's
prefix uses the existing initializer completion boundary (the same engine with
its own expression-local slots), then its final value is scheduled in the outer
session with that arm's scope and shared expected InferenceType. Do not turn a
pending hint into a TypeRef prematurely. No callback, suspended-state framework,
second solver, reparsing or generated ParsedMatch AST is involved.

The transient pending join carries accepted patterns, CheckedStatement prefixes
and completed or pending final values. A completed arm retains its CheckedExpr;
a deferred arm retains its PendingValue until its context solves. Do not freeze
an arm, discard that accepted result and repeat the work at root publication.
Both checkpoints and deferred publication use the same freezer and solver.
Replace PendingBooleanJoin with that same pending join
in the control slice, retaining typed Boolean-operand constraints and canonical
IDs; do not maintain two freeze implementations. For existing Boolean operators
and new if, freeze all written children before ordinary mismatches, then validate condition/result constraints in their
documented order, then publish only existing checked forms. Generated Boolean
constants and implicit Void carry the originating source span, not compiler origin.

Keep existing match behavior: unsupported-pattern pre-scan before scrutinee;
complete scrutinee union type before pattern/capture admission; source-order arms,
exhaustiveness, usefulness and existing first-arm diagnostics. This adds no new
backward inference from a pattern to an unresolved scrutinee type argument.

**Match checkpoints preserve the existing sequential boundaries.** True None
(UntypedValue) is different from Some(unresolved enclosing InferenceType). With
None, freeze the first arm before entering the next; that complete type becomes
FirstArmValue for later arms. A complete contextual hint likewise checks each
arm before scheduling its successor. With an unresolved contextual hint, retain
arm finals pending in that same session so enclosing siblings can solve it. Use
existing inference_complete/publication and explicit match-completion work, not
a second arm solver or a global "all children first" rule. When that hint becomes
complete, complete/check preceding arms in order before advancing. StatementArm
checks Void at each arm checkpoint; a non-Void first arm wins over a later unknown
name. Unhinted Int then String wins before a third unknown name.

Paired inference oracles use `pure func empty[T]() -> List[T]: []`. A bare bound
match whose first arm is empty() still fails UninferableTypeParameter before a
later `[1]` arm. In contrast the untyped binding below has a genuine outer hint,
even while T is unresolved, and must infer List[Int]:

```blorp
values = choose_first(
    match ready:
        True: empty()
        False: empty()
    ,
    [1]
)
```

Here `choose_first[T](first: T, second: T)` returns first; the later actual argument,
not an invented expected type, solves the pending match arms.

A root function-tail if publishes CheckedMatchBody with canonical Bool patterns,
as a tail match does; an ordinary nested if/match publishes CheckedJoin. Do not
reclassify existing not/and/or joins: their C must remain identical. Direct tail
self-calls keep existing analysis. Backedges inside nested joins remain an exact
rejection until M3, with no ordinary-call fallback for @tail_recursive.

ControlPosition is the narrow FunctionTail/NestedValue distinction, set by the
body entry, not inferred from TypeRef, ExpectedTypeSite or AnyMutableBinding.
Carry it through scheduled work. Every operand/argument/field/condition is
NestedValue, even an argument to a true tail call. Its control arms use
JoinArmLocals; only the genuine root tail's arms inherit AnyMutableBinding.
Nested control final values still produce joins, so nested backedges remain M3.
Derive the existing ReassignmentScope at arm entry from this position and the
saved binding boundary. Keep it on the existing statement/arm-prefix API, not
as an independent correlated field on expression work or elaborate_value.

Keep AnyMutableBinding only for genuine function-tail arms, as today. Value and
statement joins retain JoinArmLocals; reassigning a preexisting outer var stays
rejected until M2.1b carries it. Retain parser bans on ?= in branches. Local
annotations, loops, closures, new patterns and early returns are out of scope.

## Diagnostics and ordering

All existing accepted programs and rejection kind/message/help/full Span/notes
stay unchanged through preparation. Preserve old bare-match and logical-operator
priority in the behavior slices. For new if, plan condition first, then then/else
statically in written order; nested child failures precede ordinary condition and
branch type mismatches. Among those mismatches, condition precedes branch result.
Branch equality uses the existing inference operations, not another unifier.
This new-if ordering does not replace match's sequential checkpoints above.

| New-if expectation | Written block with no final value | With else | Without else, after child-static and condition checks |
| --- | --- | --- | --- |
| StatementValue / StatementArm | Implicit Void permitted, as existing StatementArm | Every explicit final must be Void | Void then succeeds; explicit non-Void then → IfWithoutElseValue. |
| VoidTail | IfBranchWithoutValue | Explicit finals required; values checked then discarded | Explicit Void final succeeds; non-Void → IfWithoutElseValue; missing final → IfBranchWithoutValue. |
| CheckedAgainst(VoidType) | IfBranchWithoutValue | Explicit Void finals required | Same then rule; no inferred missing-final coercion. |
| Known non-Void consumer | IfBranchWithoutValue when else exists | Explicit finals checked against consumer | IfNeedsElse wins over missing final or a non-Void then. |
| True None / UntypedValue, or Some(unresolved hint) | IfBranchWithoutValue | Pending final types converge; no first-match freeze rule is imposed on new if | Synthesize Void; explicit non-Void then → IfWithoutElseValue; missing final → IfBranchWithoutValue. |

An unresolved generic hint alone proves neither Void nor non-Void. It cannot
trigger IfNeedsElse; a Void conditional may satisfy that generic argument. If
another argument conflicts, preserve the ordinary caller-inference rejection.
No-else rejection order is: written child-static error, condition type error,
known non-Void consumer's IfNeedsElse, missing required final, then non-Void
then-value IfWithoutElseValue. No checking of an absent/generated branch occurs.

Proposed new typed sites/rejections for expert review:

| Case | Exact message / help | Primary and note |
| --- | --- | --- |
| IfCondition expected-type site | `if condition must have type Bool` / `use True, False, or an expression that returns Bool` | Full original condition Span/SourceId, including grouping; no note. |
| IfNeedsElse | `` `if` requires an else branch to produce a non-Void value `` / `add else: and return a value of the same type from both branches` | Full ParsedIf.span; no note. |
| IfBranchWithoutValue | `if branch has no value` / `end each branch with an expression of the same result type` | Offending ParsedBlock.span; no note. |
| IfWithoutElseValue | `if without else must have a Void then branch` / `end the branch with a Void expression, or add else to return a value` | Complete then value's Span/SourceId; no note. |

Existing annotation/argument mismatches keep their expected-site authority. For
unconstrained branch disagreement add FirstBranchValue, with
existing typed ExpressionTypeMismatch, rendering `if branches must return the same
type` / `return the same type from then and else`; the full failing branch-value
Span is primary and note is None, as with existing FirstArmValue. No new diagnostic
note variant or misleading declaration note is needed. No spelling lookup affects checking. Missing-value/else errors follow
static checking of existing written children; skipped branches still produce
unknown-name, arity and purity errors. Pin competing-error examples explicitly.

## Slices, costs and gates

1. **Independent mechanical preparation:** only the move/import/export cut above.
   Net production target -20…+20, hard +50; physical additions ≤850, report deletions
   and moved lines honestly. Existing phase/Boolean suites and every accepted C/
   rejected diagnostic identical. No feature flags or dormant control scaffolding.
2. **Compositional match:** complete scoped-result/BindingId and pending-arm path
   through calls, records, unions, Lists, Boolean operands, scrutinees and arm
   values. First real native identity(match ready) fixture exits 23. Remove the
   bypass and replaced join elaboration in this slice; no bare-if implementation.
3. **Full if:** multiline child expressions, statement/no-else, else-if and true
   function-tail publication; final generic String/native ownership matrix.

Combined behavior target +300 net production; hard +400 net / 650 physical added.
Overall including prep hard +450 net / 1,500 added. Test estimates separately:
1,100 lines excluding fixtures, 180 fixture lines; preserve granular coverage
rather than compressing or dropping it. Stop for root/expert rescoping above caps.

Freeze matching baseline/candidate sources, host/toolchain/flags and binaries.
For unchanged inputs, serial normal min-of-three retired instructions and separate
strict allocations: prep target ≤+1%, hard +3%; behavior target ≤+5%, hard +10%,
per input including prior Boolean cases. Frozen-host compiler build is a labelled
selfcompile proxy: prep hard +3%/+3%, combined hard +8% instructions/+10% allocations.
Never compare successful new feature costs with old unsupported rejection costs.
Investigate increases at their owner; do not add a cache or weaken an oracle.

Each slice gets root plus independent compiler-expert review and independent test
runner. TDD first; normal main fixtures, unchanged C, -O0/ASan/UBSan and strict
zero leaks. Granular tests inspect pending inference constraints, complete checked
facts, specialization, lower IDs/branch placement, own dup/drop/edge transfer,
independent malformed-IR verifier failures and emitted control placement. Cover:

- sibling/nested binding IDs after existing parameters and before a later local;
  capture IDs after nested scrutinee bindings; no branch-local escape/shadowing;
- generic identity(if ... String ...) and nested match, empty generic call context,
  rigid parameters and unchanged prefix-initializer inference limits; paired bare
  unhinted empty() rejection and choose_first(match empty/empty, [1]) acceptance;
- static skipped-name/function/arity/purity errors and exact competing priorities;
- match non-Void statement arm before later missing name, and unhinted Int/String
  disagreement before a third missing name; every table row's missing final;
- new-if missing name before wrong condition, wrong condition before no-else
  rejection, known Int consumer before non-Void/missing then, untyped no-else
  non-Void then rejection, and generic unresolved-hint Void success;
- condition once, selected arm once, no eager else-if condition or managed RHS;
- managed branch locals, returned borrowed field/outer alias, discard and path
  cleanup; Bool value joins discarded whole versus Void joins normalized per arm;
- genuine tail-if direct self call, existing tail matches, and exact nested-backedge
  rejection; contrast root tail arms with a control inside a tail-call argument
  (JoinArmLocals); unchanged outer-var restrictions and branch propagation parser errors.

Kill mutants that reuse sibling IDs, leak arm scope, freeze an arm early, skip
static branches, swap labels, duplicate condition/RHS execution, drop an outer
alias early, omit a branch temporary drop, or apply Void discarding to Bool arms.
For scope/binding mutants require typed products as well as real output; wrong
ownership must fail independent verification or runtime-helper tests.

Generate 16/32/64/128 nested and flat controls plus branch-local cases. Record
source/expanded node counts, allocations/instructions, C bytes and lexical C depth;
compile supported Clang at default limits and run ordinary main with exact output.
Preserve the known existing interval-scan/string-joining scaling attribution;
distinguish it from new scheduler/binding work. Stop on authority ambiguity,
repeated cap breach, default backend limit, host defect or required new mechanism.
Hand back bounded patches, exact red/green/mutant commands, provenance, three LOC
categories, measurements, review verdicts and limits. No production edits or
compiled commands belong to this planning task.
