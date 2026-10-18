# Boolean expressions through checked joins

The initial M2.2 design below was written against source commit
`c3b7e4294825e2707e8d30d2e38edcad86a5c384`. It implements compositional `not`,
then `and` and `or`, using the existing expression inference loop and checked
join. Implementation waits for independent compiler review and approval of
this plan. The accepted-M2 cost refresh at the end supersedes only the historical
measurement baseline/roles; general `if` stays explicitly unsupported.

## Problem and first complete example

The parser already accepts this program:

```blorp
func main() -> Int:
    match not True:
        True: 17
        False: 23
```

The checker rejects `not True` with message `` `not` is not supported yet ``
and help ``match on the Bool operand; `not` arrives with the join milestone``.
The required native result is exit 23, empty stdout and empty stderr. Its
companion with `not False` exits 17. These are the first complete vertical
slice: parser, checker, specialization, lowering, ownership, verification,
emission and the fixture's real `main`. Logical binary operators follow only
when this slice's focused checks pass.

The foundation is already ready. The owning [M1b section](ROADMAP.md#m1b-names-and-the-foundation)
says Part B is done, and current code publishes designated Bool, Option and
Result identities. The status table's older Part B text is stale; the
coordinator owns its separate correction. Do not redo foundation checking.

## Current authority and lifetime

| Fact | Producer and owner at this baseline | Consumer in this change |
| --- | --- | --- |
| Bool's canonical variants and validated nongeneric, payload-free shape | [namespace/builtins.brp](src/namespace/builtins.brp), `DesignatedBoolean` at line 30 and `CheckedFoundation` at line 419; one accepted foundation per compilation | Checker expression planning and canonical constructor construction |
| Complete signatures, arity and purity | [check/callables.brp](src/check/callables.brp), existing function contracts | Ordinary operand planning, including statically unchosen RHS |
| Body-local inference variables and pending children | [check/inference.brp](src/check/inference.brp), `PendingBase` at line 56; one expression elaboration | Existing work loop and final freezing |
| Expression planning and complete publication | [check/expressions.brp](src/check/expressions.brp), `plan_base` at line 346, `elaborate_value` at line 545, freezing at line 1012 | Existing `CheckedExpr` and `Match(CheckedJoin)` |
| Function-wide binding identities and block scopes | [check/bodies.brp](src/check/bodies.brp), ordered body checking | Unchanged; logical operators introduce no bindings or scopes |
| Void-tail discarding | [check/bodies.brp](src/check/bodies.brp), `discard_arm_values` at line 1101 | Recurse into a join's arms only when its existing checked result type is Void |
| Complete checked union branches | [check/model.brp](src/check/model.brp), `CheckedJoin` at line 254 | Existing specialization, lower, own, verify and emit |
| Runtime branch placement | [lower/lower.brp](src/lower/lower.brp), `Match` case at line 398 | Existing join arms, edge transfers and C switch emission |

The current `ResolutionContext` at `callables.brp:408` has caller, module,
namespace, signatures, unions and records, but no designation. Its sole
production construction is `bodies.brp:1016`. Plumbing is explicit:

1. `check_program` passes `foundation.designated.boolean` at its existing
   `resolve_functions` call (`check.brp:75`).
2. `resolve_functions` and recursive `check_functions` carry that accepted
   `DesignatedBoolean[VariantId]` unchanged.
3. The constructed `ResolutionContext` gains a `boolean` field. Expressions
   borrow it; no namespace query, repeated foundation validation or optional
   annotation scope is added.

Update any direct typed test construction if present after integration. The
baseline has no other production constructor. The designation remains owned
by the foundation product; passing its identities does not create another
semantic authority.

## Concrete implementation

Current `expressions.brp:371` rejects all three forms:

```blorp
LogicalExpression(_, _, _): Err(unsupported_form(body.base_span, AndOrOperator))
NotExpression(_): Err(unsupported_form(body.base_span, NotOperator))
IfExpression(_): Err(unsupported_form(body.base_span, IfValue))
```

The planned replacement is:

```blorp
LogicalExpression(operator, left, right):
    Ok(PlannedLogical(operator, left, right))
NotExpression(operand):
    Ok(PlannedNot(operand))
IfExpression(_):
    Err(unsupported_form(body.base_span, IfValue))
```

Add the two planned alternatives to existing `PlannedBase` at
`constructors.brp:690`. Moving that shared vocabulary is outside this slice.
Extend existing `PendingBase` with the direct transient counterpart of a
Boolean checked join:

```blorp
PendingBooleanJoin(
    DesignatedBoolean[VariantId],
    PendingValue,  -- scrutinee
    PendingValue,  -- True arm
    PendingValue,  -- False arm
)
```

This fixed two-arm carrier holds pending expression children until the
existing publication boundary. It adds no checked Boolean tree, backend
special case or additional IR phase. Its result type is the complete
`UnionType(variant_owner(boolean.true_variant))`.

Canonical constants are constructed from accepted facts, without calling
`find_variant`, `plan_variant`, `function_contract` or a declaration-shape
lookup. The existing complete transient contract at `inference.brp:442` is:

```blorp
fixed record PendingVariantContract {
    variant: VariantId,
    result_type: InferenceType,
    fields: List[InferenceUse],
    span: Span
}
```

For example, given the accepted `boolean`, a generated False value has:

```blorp
boolean_type = UnionType(variant_owner(boolean.true_variant))
contract: PendingVariantContract = {
    variant = boolean.false_variant,
    result_type = AcceptedType(boolean_type),
    fields = [],
    span = expression_span
}
value: PendingValue = {
    span = expression_span,
    readiness = ClosedInference,
    base = PendingConstructVariant(contract, []),
    base_type = AcceptedType(boolean_type),
    base_span = expression_span,
    operations = NoPendingOperations
}
```

The already accepted designation proves the empty fields and nongeneric
result. True uses `boolean.true_variant` through the same narrow helper.
The generated constants use the enclosing expression's actual source span;
there is no fabricated parsed name or synthetic source inventory.

Freezing produces ordinary `CheckedJoinArm`s with empty statement prefixes
and canonical `VariantCase(id, [])` patterns:

| Source | Scrutinee | True arm's value | False arm's value |
| --- | --- | --- | --- |
| `not operand` | operand | canonical False | canonical True |
| `left and right` | left | right | canonical False |
| `left or right` | left | canonical True | right |

All checked arms and the scrutinee have designated Bool type. The complete
published expression is `Match(CheckedJoin)`, with the written expression's
span. Its downstream representation is exactly the existing join.

## Static checking, inference and runtime order

Each written operand enters the existing work loop, left before right, with
a designated Bool hint. Both operands are planned and checked even when a
literal makes one dynamically unreachable. The complete postfix planning
path remains active, so `(not ready).identity()`, call arguments, list and
record children, nested Boolean operators, match scrutinees and match-arm
values compose with existing supported expressions.

Hints remain advisory. Add `BooleanOperandConstraint(Span)` to existing
`ConstraintOrigin`. After operand planning, schedule ordinary inference
equalities between each operand's pending type and accepted Bool, with
`RequireEquality`. Extend every exhaustive origin observer: argument-origin
recording, span selection, mismatch handling, conflict handling and occurs
error context. Boolean constraints do not set or consult the root's
`IncompatibleResultInference` state. A structural Bool mismatch is deferred
to the Boolean node's complete-type validation, like the existing
field/variant mismatch boundary, rather than suppressing later constraints.

Nested operators share the enclosing expression's slots. An inner Boolean
join can have a known Bool result while a child call still has an unresolved
or phantom generic parameter. Its readiness must remain `DeferredInference`
if any written child is deferred. Do not mark it closed merely because the
result type is Bool, discard pending children, or freeze early. Operand
constraints can solve expression-local call variables; declaration-owned
rigid `ParameterType`s never unify with Bool. The enclosing result's expected
type continues through normal postfix hints and result constraints; it does
not change the operators' Bool operand/result rule.

Diagnostic order is concrete:

1. Existing postfix contract and expression-entry checks retain their order.
   Written child planning visits left before right, recursively. Name,
   arity, purity and unsupported-form failures are reported there; an
   ordinary left type mismatch cannot hide a later RHS name error.
2. Run the existing inference work and operand constraints. Existing child
   generic conflicts keep their established phase and source order.
3. During freezing, finish written child subtrees in source order. At each
   Boolean node, freeze both immediate written operand subtrees before
   validating their ordinary Bool-type mismatches, left before right.
   A nested child's own error precedes its parent's mismatch. Do not promise
   a global reordering across separate subtrees.
4. A Boolean operand mismatch uses existing `ExpressionTypeMismatch`, a new
   `ExpectedTypeSite.BooleanOperand`, expected designated Bool, actual
   complete type and the operand's exact span. Message:
   `Boolean operand must have type Bool`. Help:
   `use True, False, or an expression that returns Bool`.
5. A valid Boolean expression in an incompatible outer context retains the
   existing outer annotation or binding diagnostic, anchored at that
   expression. Unknown-name and purity failures retain their own spans.

Compile-time operand scheduling performs no target execution and emits no
lowered definitions. The pending RHS is frozen solely into the selected
checked arm shown in the table. Lowering therefore places its calls,
String allocations and temporary cleanup inside that arm; it never places
RHS definitions in the join's enclosing block. The scrutinee executes once.
For nested operators this rule applies recursively.

## Void-tail consumer correction

Independent review identified one necessary consumer fix. The current
`bodies.brp:1101` unconditionally rewrites the arms of any directly discarded
`Match` to Void:

```blorp
private pure func discard_arm_values(value: CheckedExpr) -> CheckedExpr:
    match value.form:
        Match(join):
            var arms: List[CheckedJoinArm] = []
            for arm in join.arms:
                discarded = discard_tail_value(arm.statements, arm.value)
                arms = arms.append({ arm | statements = discarded.statements, value = discarded.value })
            { value | form = Match({ join | arms = arms }) }
        _:
            value
```

That assumption currently follows from source matches resolved under
`VoidTail`. A new `func main(): not True` instead produces a Bool join.
Rewriting its arms to Void while leaving its result Bool would make the
verifier reject `yield type does not match its join`.

Use the existing `CheckedExpr.value_type` to restrict the recursion:

```blorp
private pure func discard_arm_values(value: CheckedExpr) -> CheckedExpr:
    match value.form:
        Match(join):
            if same_type(value.value_type, VoidType):
                var arms: List[CheckedJoinArm] = []
                for arm in join.arms:
                    discarded = discard_tail_value(arm.statements, arm.value)
                    arms = arms.append({ arm | statements = discarded.statements, value = discarded.value })
                { value | form = Match({ join | arms = arms }) }
            else:
                value
        _:
            value
```

`discard_tail_value` then discards a Bool join whole and returns canonical
Void, preserving its Bool arms and single evaluation. Existing Void source
joins still recursively discard their selected tail values, including a
Boolean join nested as one such value. Ordinary value-returning Bool joins
and existing statement-match behavior stay intact. Update the inaccurate
nearby comment to state this type distinction. An `InvokeFunction` postfix
wrapper is already discarded whole by the existing wildcard case and needs
no change. This correction adds no origin flag, IR form, lowering change or
block-inference preparation.

## Ownership, tests and mutation evidence

Bool is an ordinary unmanaged union. Logical operators introduce no new
binding IDs or scopes. Existing joins borrow prefix owners, transfer their
selected value, and discharge arm-local owners. RHS calls may receive an
outer String alias and create managed arguments or temporaries; those
values still use the existing join ownership rules. No runtime helper is
added. Existing String helper lifetime tests remain applicable; balanced
compiler counters are not evidence of target object destruction.

Start with new `test/unit/test_check/test_boolean.brp`, the first `not`
fixture above and its companion. Check complete typed products, canonical
variant IDs and spans. Then add:

- Full truth tables, nesting, precedence, receiver postfixes, direct/UFCS
  arguments, constructor/list/record children and existing match positions.
- Expected generic constructor context such as `not identity(False)`,
  generic calls resolved to Bool, unresolved phantom parameters in a
  statically skipped RHS, and a rigid generic operand rejection.
- Unrelated two-variant unions, shadowed constructor spellings and wrong
  left/right/not types. Pin typed errors and exact rendered text/help/span.
- Unknown names and impure calls in a statically unchosen RHS. Pin the
  diagnostic-order examples above, including nested-child errors.
- Void-tail typed products: a directly discarded Bool join retains Bool
  arms; the function returns canonical Void; a Void source join around a
  Boolean value recursively discards only the outer Void join. Include
  existing statement-match behavior and an unaffected `InvokeFunction`
  postfix wrapper as preservation cases.

Add granular typed-input/output tests at inference, checker, lower, ownership,
independent raw verification and emission boundaries. Lower and emitter
assertions must place RHS calls and managed allocations inside the chosen
arm. Ownership tests cover an outer alias remaining live after the join and
RHS temporary cleanup; raw malformed ownership must still be rejected.

Add a normal `test/e2e/test_boolean.brp` suite and real-main fixtures under
`test/e2e/fixtures/boolean/`. A `probe(label, value)` prints its label and
returns Bool. Exact stdout distinguishes skipped RHS, selected RHS once,
left-before-right effects, nested selection and swapped variants. A managed
case passes fresh String text and an outer alias through the RHS, then
prints the alias afterward. Use ordinary fixture compilation, unmodified C,
ASan/UBSan and normal entrypoints. C placement establishes that skipped
allocating expressions stay in the branch; do not claim a new independent
runtime allocation-count oracle.

Add actual Void-main regressions: `func main(): not True` must exit 0 with
empty stdout/stderr; a Void-returning tail-match arm containing
`False and probe("skipped", True)` must exit 0 without printing; and a
nested source join resolved under `VoidTail` around a Boolean expression
must preserve the inner Bool arms and execute the selected effects exactly
once. Complement the skipped probe with a selected probe, checked by exact
stdout, so discarding cannot silently erase or duplicate evaluation. Keep
ordinary Bool-returning cases to catch an over-broad Void conversion.

The nested Void-tail fixture uses the normal entrypoint and must print
exactly `selected\n`, with exit 0 and empty stderr:

```blorp
import:
    io: print

func probe(label: String, value: Bool) -> Bool:
    print(label)
    value

func main():
    match not False:
        True: match not True:
            True: not probe("never", False)
            False: not probe("selected", False)
        False: not probe("outer-skipped", True)
```

Implementation preparation corrected these scrutinees from bare `True` and
`False`: existing match checking requires an already-typed union expression.
The logical forms supply the designated Bool type without extending bare
constructor inference, while preserving the same selected effects and Void
join normalization oracle.

Prove the tests by deliberate temporary mutations: swapped canonical labels,
RHS work moved before the join, skipped static RHS checking, bypassed Bool
validation, and omitted RHS cleanup against the existing ownership/lifetime
oracles. Restore the old unconditional `discard_arm_values` behavior as a
separate mutant: the typed-product and actual Void-main/tail-match
regressions must fail. Restore each mutation. Do not call generated internal
functions or rewrite fixture C.

Remove only the obsolete `not` and `and/or` unsupported cases. Keep the exact
`if` rejection. All previously accepted fixtures must emit byte-identical C;
any exception requires explicit explanation and review. Preserve all existing
fixture cost limits and the measured parser frontier for the actual source tree.

## Scope, costs and acceptance

Production scope is `check/{check,bodies,callables,constructors,expressions,
inference,errors,render}.brp`; no production lower/own/verify/emit change is
expected. Bodies changes include the designation plumbing and the bounded
Void-tail normalization correction above. Root owns integration and shared
README/grammar/roadmap updates.
There is no parser change. Expected production growth is 190–240 physical
lines; stop above **260 net added / 300 added physical production lines**.
Report deletions and additions plainly, without formatting compression.
Separate estimates are 900 test lines, 200 fixture lines and 60 implementation
documentation lines, excluding this plan and evidence report. Necessary
granular coverage is not dropped to meet those estimates; report any growth
separately. The production ceiling remains binding across the entire slice.

Initial numerical ceilings per new fixture, set before implementation:

| Fixture class | Compiler allocations | Retired instructions |
| --- | ---: | ---: |
| Truth, composition or effects | 30,000 | 180,000,000 |
| Managed RHS | 45,000 | 220,000,000 |

These are acceptance limits, not measurements. For each frozen shared input,
retain the roadmap's +5% allocations and minimum-instructions target and
+10% hard rejection ceiling. Use at least three serial instruction samples;
no average hides an individual input failure. Compare against the matching
`c3b7` pilot supplied by the coordinator, preserving source, host/compiler
binary, flags, input and output hashes and raw samples. Owned-input costs
remain self-compilation proxies.

Exercise flat and right-nested expressions at 16/32/64/128 nodes. The new
checker work should be linear in Boolean nodes plus existing child work.
Investigate repeatable near-quadratic doubling. Record emitted C structural
depth, and compile nesting stress with supported toolchains at default
limits. Report inherited scaling separately; do not add flattening, an index
or a new mechanism to evade a failure.

The following initial frozen-host recipe is historical; the accepted-M2 refresh
below owns current roles. Originally, only after a serialized lane grant, run the host
against the exact new suite, followed by affected checker/inference and
join phase suites:

```sh
boolean_host=/Users/keithphilpott/.codex/worktrees/blorp-2-compiler-comparison/blorp/bin/blorp
"$boolean_host" test --suite --timeout 180 blorp_2/test/unit/test_check/test_boolean.brp
```

The frozen host SHA-256 is
`899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`.
Use it to build the candidate pilot once, linked at `-O0` with
`BLORP_MEMORY_DIAGNOSTICS=1`; do not build another host. The normal e2e suite
receives that candidate explicitly through its existing harness. The root's
independent test runner owns integrated `make -C blorp_2 test` and
`scripts/blorp2-fixpoint --frontier`, with the frozen host wired into the
root's established build setup. No compiled commands are part of the plan's
docs-only validation.

Independent compiler and docs test-runner review precede the coordinator's
docs-only commit. Implementation then requires focused red/green, deliberate
mutant failures, phase-product evidence, exact native outcomes, unchanged
existing C, matched costs, scaling/depth evidence and independent compiler
review before integration. Hand back exact supported forms, physical counts,
provenance, raw artifact paths and unresolved limitations.

Keep `if`/`else if`/`else`, `?=`, annotations, loops, closures, constants and
new patterns out of scope. Existing `JoinArmReassignment` and nested-join
self-tail-call rejections remain unchanged. Full `if` needs an explicit later
preparation: body checking currently owns block-local BindingDefinitions,
while expression elaboration owns shared inference slots and returns only a
CheckedExpr. Do not add a bare-only `if`, callback framework, inferred scope,
second checker path, new pipeline, cache or IR to bypass that boundary. Stop
on a host bug, ambiguous authority, ceiling breach, missing ownership oracle
or need for an additional mechanism. No commits or pushes by the worker.


## Prospective accepted-M2 cost refresh

This bounded Boolean FEATURE refresh is prospective: no current cost setup,
freeze or sample exists, and no failed epoch is retargeted. The initial c3b7 B,
899e functional host and later unexecuted FULL-exit TOTAL proposal remain history;
none supplies current acceptance. Root and independent review approve this
maintained contract and the actual packet before any cost preparation or freeze.

Freeze one actual then-accepted M2 B and complete Boolean C source and target
library, with the complete current registered CLI states, fixture/generated
inputs, output preconditions and preserved sentinels. Name B before sampling;
never roll it to C, refreeze after failure or select a smaller changed corpus.
Keep the original unsupported not/and-or program bytes as shared inputs despite
their removed e2e registrations: only their enumerated typed diagnostic changes
are intentional. Include all new Boolean cases separately, with no invented B.
Do not copy historical503-state/3988-call totals into a new registry.

For every shared input, keep the **+5% target / +10% hard rejection** limits for
allocations and normal minimum-of-three positive retired instructions. Apply the
same target/hard limits to the parent-owned compiler-source construction proxy.
Report every target miss even below the hard ceiling; root reviews it explicitly.
Keep all stricter absolute fixture caps, positive balanced strict-zero target
reports, exact shared C/status/diagnostics/output-state oracles (except the two
explicit diagnostic changes), and within-variant strict/normal identity. No
aggregate average, offset, subtraction or unrelated improvement hides a breach.

Retain the original producer/normal proxy SHA256
`34ac1a913c79fc14130c77fe4339f24885a2fa65f1d25fc4b873b627e10e1f33`,
diagnostic proxy `be31a5a3a070deef54707d8676a7c6157042484f40d0424dd5fb46835c09ff93`,
and their explicit original host std tree `090ed68c5bd688cb8e2197c72bc572e4dc32e6d7`.
Verify complete existing598 host-input pins and actual binary provenance before
reuse. The diagnostic proxy observes exactly the original schema1
`artifact_construction_complete.total_allocations`, with BLORP_MEMORY_STATS=1,
BLORP_LEAK_CHECK unset, status0 and one exact checkpoint row. Normal proxy runs
unset both memory modes and use B1,C1,C2,B2,B3,C3/min3 instructions. Preserve each
variant's generated compiler C against its own once-generated setup C, and review
intentional B/C compiler-source differences raw. This proxy is not self-compilation.

The existing ROOT c04/explicit ROOT std91 role is FUNCTIONAL TestSuite/pilot
production only, never a substitute for the original construction metric/host.
No FULL-exit TOTAL, SOURCE3% substitution, inherited unary/HOF exception or old
host-borrow exception is granted. Missing original provenance is STOP, not fallback.
Accepted M2 carried facts remain the baseline; historical reassignment rejection
wording above does not restore a removed restriction. All physical ceilings,
semantic scope, scaling/default-depth, native/sanitizer, review and destination
gates remain unchanged. Source migrations retain their separate cumulative rules.
