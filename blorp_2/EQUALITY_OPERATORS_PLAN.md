# Built-in equality operators

Status: operator implementation complete on `a9b193915`, following two independent
approvals of the design based on `5a88da075`. The user requested landing after
functional qualification; remaining sanitizer, fault and matched-cost checks are
recorded as pending in the benchmark report. This document is the implementation
handoff; review findings and execution evidence belong under ignored `build/`,
not additional plan files.

## Problem and scope

The library already dispatches equality through static traits, but callers
still write `IntOps.equals(count, length(right))`. Add only two compiler-owned
operators:

| Syntax | Selected canonical member |
| --- | --- |
| `left == right` | `Equatable.equals` |
| `left != right` | `Equatable.not_equals` |

Users implement these ordinary trait methods for their types. They cannot
declare symbols, change operator mappings, register operators, or change
precedence. Arithmetic, ordering, compound assignment, logical-operator
implementation, coercions and comparison chains are outside this increment.
Legacy compiler production sources remain untouched; legacy serves only as
the temporary TestSuite host. Compiler/library comparisons migrated once an
operator-capable bootstrap was published and pinned.

## Current boundaries and reproduction

Read parent/B2 AGENTS and [HANDOFF_SPEC](../docs/HANDOFF_SPEC.md). Relevant
current boundaries, rather than a second general trait design:

- `src/lex/lex.brp:802`, `literal_or_symbol`: adjacent punctuation recognition.
- `src/utils/syntax.brp:263`: parsed operator/value variants.
- `src/parse/parse.brp:1555` and `:2707`: ordinary precedence and the separate
  parenthesized statement/destructuring entry.
- `src/check/traits.brp:69`, `:261`, `:265`: canonical contract admission and
  prelude-selected identity. Today only abstract `equals(Self, Self) -> Bool`
  is required; compatible additional default methods are allowed.
- `src/check/model.brp:205`, `:212`: accepted traits and accepted method calls.
- `src/check/callables.brp:335`, `expressions.brp:1410`,
  `inference.brp:1694`: method contract, ordered argument work, final dispatch.

First red fixture, compiled with Blorp 2, not the host:

```blorp
func main() -> Int:
    match 7 == 7:
        True: 23
        False: 0
```

```sh
make -C blorp_2 test-compiler
mkdir -p blorp_2/build/equality-operators
blorp_2/build/compiler --library-root blorp_2/standard_library \
  blorp_2/test/e2e/fixtures/equality/operators.brp \
  blorp_2/build/equality-operators/operators.c
```

The fixture is to be added by the implementer. Currently the lexer produces
two assignment tokens for `==`; this is not an accepted comparison. `!=`
contains an unsupported `!` byte. Retain actual first diagnostics when making
the red tests; do not invent their current wording. Expected final behavior:
successful C generation and real native `main` exit 23.

## Language rules

1. Symbols target the actual canonical trait selected by the configured
   prelude, independently of imports of `equals` or `not_equals`. A local free
   function or unrelated trait with these spellings cannot redirect them.
   Implementation lookup and coherence remain the existing loaded-program rules;
   operators do not discover new modules or introduce new implementation scopes.
2. Both operands share the existing method signature's `Self`. Reuse ordinary
   argument inference, expected-type constraints, purity, bounds, nominal
   identity and finite-specialization checks. A Bool result supplies no evidence
   about an otherwise unknown operand type. No new equality inference algorithm.
3. Evaluate operands exactly once, left then right, eagerly. Impure operands
   remain legal in impure callers; normal purity rules reject them in pure code.
4. `!=` invokes the selected `not_equals`, including a written override; it
   never silently becomes negated `equals`.
5. Keep equals-only canonical declarations valid: `==` works. If `not_equals`
   is absent, `!=` reports at its operator token:
   **“canonical Equatable does not define not_equals”**, help
   **“add a pure not_equals(Self, Self) -> Bool default to the selected trait”**.
   If that named canonical member is present, validate its pure, two-Self-to-Bool
   default contract once during declaration admission. Reject malformed presence
   there, even if unused, with **“canonical Equatable.not_equals requires pure
   (Self, Self) -> Bool with a default body”** and help
   **“use that signature and provide a default body, or rename this helper”**.
   Ordinary method-signature validation runs first, retaining its existing
   diagnostics for impure/generic methods, unknown annotations, invalid Self
   positions and duplicate parameters. Existing malformed-canonical/extra-abstract
   validation also precedes this check: an abstract `not_equals` retains that
   existing failure. The new diagnostic applies after ordinary signature
   acceptance, for example to a default with wrong arity, second parameter or
   return type. Pin mixed-error precedence with an unknown annotation plus wrong
   canonical return type, and retain the existing diagnostic for an impure default.
6. Without a canonical binding, either symbol reports at the operator:
   **“equality operators require the canonical Equatable trait”**, help
   **“select Equatable in the configured prelude”**. Unavailable implementations,
   field notes, missing bounds and argument conflicts retain their existing typed
   errors and teaching text. Their call-origin span is the operator; operand
   errors retain the corresponding operand's span.
7. Preserve closed module-constant initialization restrictions. Operator syntax
   does not authorize evaluating trait calls in constant initializers.

Examples of the intended surface, not additional language features:

```blorp
pure func same[Value: Equatable](left: Value, right: Value) -> Bool:
    left == right

-- Missing Value: Equatable is rejected even if all callers pass Int.
-- A result annotation of Bool cannot infer the element type of [] == [].
```

### Fixed grammar and source positions

Lowest to highest: `or`, `and`, prefix `not`, comparison, range, postfix.
This follows the intended [language precedence](../docs/GRAMMAR.md#35-expressions),
not the documented legacy parser deviations. Logical forms stay unsupported by
the B2 checker; parser tests for their shapes are not feature-enablement tests.

```ebnf
comparison_expr = range_expr [ spaces ("==" | "!=") spaces range_expr ] ;
not_expr        = "not" required_spaces not_expr | comparison_expr ;
```

Recognize adjacent `==` and `!=` before single `=`. Preserve `?=`, comments,
Strings, Chars and interpolation boundaries. `a==b` is valid; `! =`, lone `!`,
`===` and `!==` are rejected with located diagnostics. No generic operator lexer.

Reject `a == b != c` at the second comparison token: **“comparisons cannot be
chained”**, help **“compare each pair separately, or parenthesize an intended
nested comparison”**. `(a == b) == c` is explicit nesting and uses ordinary typing.
`not a == b` parses as `not (a == b)`; `a == not b` needs parentheses, while the
already-supported ordinary `not(b)` call remains an operand.

Outside brackets, a newline after the operator does not continue its operand;
do not add layout continuation. Inside brackets the existing lexer suppresses
layout, so multiline grouping works. Preserve the parser's `inline`, `ending`
and `owed` facts: a completed block or indented method chain ends at its Dedent.
Update **both** expression entry paths, including
`consume_parenthesized_line_value`, whose current rest chain is range → and → or.
Its replacement is range → comparison → and → or. Tuple binding classification
still wins when `(a, b)` is followed by assignment `=`.

## Compiler implementation

### Parsed representation

Add two punctuation tokens and a closed parsed enum. The following is the
proposed actual Blorp shape in `utils/syntax.brp`, beside `LogicalOperator`:

```blorp
union EqualityOperator:
    EqualOperator
    NotEqualOperator

-- New ExpressionBase arm: retain the operator span for diagnostics and the
-- original operands. ValueExpression retains the complete expression span.
-- EqualityExpression(EqualityOperator, Span, ValueExpression, ValueExpression)
```

Do not manufacture a parsed identifier named `equals`, a fake source name,
or a user-configurable operator declaration. Update every exhaustive parsed
observer/walker using existing ownership of that traversal, without a new walk.

### One canonical contract authority

Current `AcceptedTraits.canonical: Option[TraitId]` becomes one optional accepted
canonical descriptor. Do not keep a second parallel ID/method map. Proposed
representation, using the existing opaque model idiom:

```blorp
private fixed record CanonicalEqualityContents {
    equals: TraitMethodId,
    not_equals: Option[TraitMethodId]
}
opaque type CanonicalEquality = CanonicalEqualityContents
```

Derive its trait owner through `trait_method_owner(equals)`; do not also store
the redundant TraitId. Resolve reserved member names using interned foundation
NameIds once at canonical contract admission. Add `not_equals_word` to the
existing foundation vocabulary. The descriptor contains identities, not copied
signatures. Its producer validates the required signatures and matching owner.

Keep the type/private contents/packing factory/getters in `check/model.brp`, like
`AcceptedMethodCall`; semantic admission remains in `check/traits.brp`. A factory
packs already accepted facts and is called by the contract producer. Do not
create model → traits → model imports or a new proof/registry module. Return one
small accepted contract product from `accept_trait_contracts` containing its
declarations and optional descriptor, then transfer it through implementation
validation into `AcceptedTraits`. Do not publish a partially validated
`AcceptedTraits` with placeholder implementation data. The temporary designated
TraitId remains an admission input, not a second published canonical authority.

The four current `.canonical` consumers in `traits.brp`/`recursion.brp` project
the owner from the descriptor. Existing availability, derivation and finite-use
logic otherwise remain unchanged. Measure the carrier; do not assume it is free.

### Reuse ordinary checked calls

Today `method_contract` requires a `WrittenName` for ordinary arity diagnostics.
Extract only the small shared method-ID/signature lookup needed by both callers;
an operator already has exactly two operands and an admitted signature. Build
the existing `FunctionContract { target = MethodTarget(id), signature, span }`
with the operator span. No synthetic WrittenName or duplicate call checker.

In `plan_body_base`, the parsed operator selects the accepted canonical member
and enters `PlannedCall` → `ScheduleCall` → `PendingMethod` →
`publish_pending_call` → `accept_method_call`. Preserve the existing ordered
operand work and full-expression result placement. Checking publishes the same
`InvokeFunction`/`TraitMethod(AcceptedMethodCall)` as an ordinary explicit call.

There is **no new checked operator form**, specialization dispatch path,
lowered node, ownership rule, runtime helper, layout state, or emission case.
Specialization receives the existing typed method identity/receiver and selects
the ordinary body. Required test-builder/observer updates are mechanical only.

## Test and measurement contract

Use Blorp TestSuites and ordinary fixture mains. Add focused lex, parse and Check
owners, then register the new native fixtures with the existing e2e harness.

| Boundary | Required observations |
| --- | --- |
| Lex | adjacency, assignment/propagation unchanged, comments/literals/interpolation, EOF/malformed punctuation; exact token kinds and spans |
| Parse | both entry paths, postfix and range precedence, grouping, supported block endings, bracket multiline versus bare newline, second-token chain error; exact AST and diagnostic spans |
| Check | canonical method IDs with no method import; unrelated/free-name shadowing; absent canonical; equals-only and malformed inequality contracts; scalar/String/Bool/opaque and derived/generic receivers |
| Inference | typed sibling literals in both orders, empty Lists and nominal constructors compared with explicit-call behavior; unknown/ambiguous Self stays rejected; mixed types, missing bound/implementation and finite-use failures preserve exact errors/notes |
| Context | nested calls, return/argument annotations, closures/default bodies and ordinary purity failures; closed constants still reject calls |
| Specialize | operator and explicit-call counterparts produce the same existing concrete targets; no operator-specific state downstream |
| Native | scalar/String/NaN, derived record/union, managed aliases/nested Lists, generic bound; exact main/stdout, positive balanced strict reports and ASan/UBSan |

The authored inequality oracle must distinguish dispatch from negation:

```blorp
fixed record Marker { value: Int }
implements Equatable for Marker:
    pure func equals(left: Self, right: Self) -> Bool:
        False
    pure func not_equals(left: Self, right: Self) -> Bool:
        False
-- main constructs two Markers and returns 23 iff left != right is False.
-- Negating equals would incorrectly return True and fail that real main.
```

A second native oracle uses impure String-producing operands that print `left`
and `right`; require `left` followed by a newline, then `right` followed by a
newline, once each, plus the expected main.
Mutate inequality member selection and argument order independently, observing
the named failures; do not rewrite emitted C or replace fixture mains. Read
generated C to verify ordinary call targets and ordered operand evaluation.
Include 64 explicitly parenthesized nested Bool comparisons, with the existing
parser-depth rules and exact real-main outcome. Compile under default C compiler
limits, record emitted nesting depth, and compare with explicit-call nesting;
do not add a new recursion budget or depth framework.

Runnable feedback sequence, after verifying/building the repository host:

```sh
scripts/compiler-build-status
# Run make first if that host is not FRESH. Host executes TestSuites only.
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lex/test_equality_operators.brp \
  blorp_2/test/unit/test_parse/test_equality_operators.brp \
  blorp_2/test/unit/test_check/test_equality_operators.brp
make -C blorp_2 test
BLORP_2_RESOURCE_POLICY=record-allocation-debt \
  BLORP_2_INSTRUCTION_CHECK=disabled scripts/blorp2-fixpoint --prove
```

Serialize compiled jobs. Reuse maintained strict/sanitizer harnesses and actual
B2-produced compiler C. Require actual self-built B to compile the whole current
source under diagnostic strict-memory checking and ASan/UBSan, in addition to
native fixture checks. Retain B/C output identity, the single positive balanced
leak report, and zero sanitizer diagnostics; this exercises the canonical
descriptor's lifetime with the active default prelude. Check exact CLI failures
with absent output and an
unchanged existing sentinel; broad cost-debt policy never excuses semantic,
platform, ownership or sanitizer failures. Do not invent new gate runners.

Freeze matched parent/candidate genuine self-built normal/diagnostic pairs,
toolchain/flags, source/library, environment, order and physical output before
sampling. Measure whole current-source self-compilation, unchanged return-zero
and membership controls, and a modest equality-versus-explicit-call fixture.
Retain all samples/RSS/C identity, allocations and normal min3 retired
instructions. Current-parent whole growth above 2% requires investigation;
5% in either metric requires rejection/rescoping. Preserve the existing frozen
Original trait-roadmap cumulative 5% ceilings on their original workload; do
not compound different workload percentages or relabel inherited debt.
Investigate above +200 net handwritten compiler lines; ceiling +300 net.
Report gross additions/deletions and production/tests/docs separately. Necessary
coverage is not deleted or compressed to fit; larger scope gets a review decision.
Record results in one `benchmarks/results/` report, with raw data under `build/`.

## Milestones and handback

1. **Operator support:** one mergeable lexer → Check → existing call path,
   fixtures, grammar/README/GUIDE updates and measured report. Add red tests
   first; no parse-only main commit. Keep implementation/library source syntax
   compatible with the currently pinned seed. Two independent code and
   test-result approvals are required before integration.
2. **Bootstrap:** use the maintained release workflow and
   [release procedure](../docs/RELEASES.md). Qualify/publish actual binaries,
   verify all target digests/provenance, then pin them. Fresh seed-only build
   and actual producer/output identity must close before source migration.
3. **Usage:** a separately reviewed, bounded migration to `==`/`!=`, beginning
   with `standard_library/list.brp:56`. Update compiler-source subset guidance
   when the pin permits it. Preserve real custom `not_equals` semantics and
   measure self-compilation again. Do not rewrite unrelated ordering/arithmetic.

Workers return branch/base/exact diff, source/binary identities, focused and full
gate results, diagnostic/oracle evidence, production/test line counts, matched
metrics and remaining limitations. Stop for a new mechanism, downstream operator
state, repeated semantic authority, exceeded hard ceiling, or an unresolved
language rule; report the concrete conflict rather than route around it.
The coordinator owns final review, serialized integration and publication.
Implementation is authorized. Land the complete reviewed operator increment;
bootstrap publication and source migration follow the separate milestones above.
