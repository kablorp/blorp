# Built-in ordering operators

Status: step 2 adds the operators. Step 0 made ordering the ordinary trait
`Orderable` in `_base.brp` (`8eb7777c5`), and step 1 extracted the shared
canonical member checks (`c45796a03`). The seed rotation and the source
migration follow as separate steps. This document
mirrors [the equality operators plan](EQUALITY_OPERATORS_PLAN.md), whose rules
apply unless a section below says otherwise.

## Problem and scope

Ordering was spelled as calls, `left.less_than(right)`, and `<` was an
unsupported character. Add four compiler-owned operators:

| Syntax | Selected canonical member |
| --- | --- |
| `a < b` | `Orderable.less_than` |
| `a > b` | `Orderable.greater_than` |
| `a <= b` | `Orderable.less_than_or_equal` |
| `a >= b` | `Orderable.greater_than_or_equal` |

Owner decisions (2026-10-29): `less_than` is the one abstract member and the
other three are defaults; the trait is named `Orderable`; every ordering
comparison involving a Float NaN is false. Out of scope: `compare -> Ordering`,
`min`/`max`, ordering for String, List, tuples or records, arithmetic operators
and comparison chains.

## Language rules

The equality plan's language rules 1 to 4, 6 and 7 apply with Orderable in
place of Equatable:

- The configured prelude's ordinary `Orderable` binding selects the trait. A
  user trait or function spelled `Orderable` or `less_than` cannot redirect an
  operator.
- Each operator invokes its own selected member, including a written override.
  `>=` is never a negated `<`, and `>` is never a swapped `<`.
- Both operands share `Self` and go through ordinary inference, purity and
  bounds. They are evaluated once, left then right. A Bool result supplies no
  evidence about the operand type.
- Without a canonical Orderable, each operator reports at its token:
  **"ordering operators require the canonical Orderable trait"**, help
  **"select Orderable in the configured prelude"**.

Equality's rule 5 (an optional member) has no ordering counterpart. All four
members are required, so admission rejects a missing or malformed default even
when no operator uses it, and dispatch needs no missing-member diagnostic:

- `less_than` must be the sole abstract method, a pure `(Self, Self) -> Bool`:
  **"canonical Orderable requires pure less_than(Self, Self) -> Bool as its sole
  abstract method"**, help **"keep less_than abstract; other pure methods require
  default bodies"**, at the trait's name.
- Each other member must be present with a default body and that signature:
  **"canonical Orderable.<member> requires pure (Self, Self) -> Bool with a
  default body"**, help **"use that signature and provide a default body"**, at
  the member's name, or at the trait's name when the member is missing.

Orderable is never derived. A record, union or opaque type without a written
implementation reports **"receiver does not implement Orderable"**. This change
names the trait in that existing message for every trait, which used to say
"this trait". An `Orderable` bound does not provide `==`.

### Grammar and lexing

All six comparisons share one level, between prefix `not` and ranges, and do
not chain with one another: `a < b < c`, `a < b == c` and `a == b < c` are
rejected at the second operator, on both expression entry paths.

```ebnf
comparison_expr  = range_expr [ spaces comparison_op spaces range_expr ] ;
comparison_op    = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
```

`->` is recognized before `>`, and `a<-1` lexes as `<` before the literal
`-1`. Three spellings from other languages are rejected in the lexer, where
both bytes are known, with spans covering both:

| Input | Message | Help |
| --- | --- | --- |
| `=>` | `'=>' is not an operator` | `write '>=' to compare, or 'func(x): expr' for a lambda` |
| `=<` | `'=<' is not an operator` | `write '<='` |
| `<>` | `'<>' is not an operator` | `write '!=' for inequality` |

`<<` and `>>` lex as two comparison tokens; the parser rejects the second with
its ordinary "expected a return expression".

## Compiler implementation

- **Syntax.** `EqualityOperator` became the flat six-case `ComparisonOperator`,
  and `EqualityExpression` became `ComparisonExpression`.
- **Lexer.** Tokens starting with `=`, `<` or `>` are told apart by their
  second byte in one branch per first byte, so other tokens pay one test per
  first byte rather than one per two-byte spelling.
- **Canonical contracts.** `AcceptedTraits.canonical` is a
  `CanonicalContracts { equality, ordering }` record. `CanonicalOrdering` is an
  opaque record of the four member identities with no optional fields. Both
  contracts are admitted once, in `accept_trait_contracts`, from the shared
  `sole_abstract` and `default_member` checks; `designated_trait` takes the
  foundation word of the trait it selects. The availability, derivation and
  orphan consumers read `.equality` only.
- **Errors.** A closed `CanonicalFamily = EqualityFamily | OrderingFamily`
  parameterizes `OperatorRequiresCanonical`, `MalformedCanonicalTrait` and
  `MalformedCanonicalMember`, and render selects the text by family. Equality's
  texts are unchanged. `MalformedCanonicalMember` carries the member's
  foundation `NameId` rather than a `TraitMethodId`, because a missing ordering
  member has no method identity; its name is spelled only when rendering.
- **Dispatch.** `comparison_contract` selects the member from the operator in
  one match and enters the existing checked trait-call path. There is no new
  checked form, specialization path, ownership rule or emission case.

The pinned seed predates these operators, so compiler and standard-library
source keep writing ordering as calls until the seed is rotated.

## Tests

- Lex, parse and check suites (`test_ordering_operators.brp` in each), all
  registered in the Makefile's `TARGET_COMPONENT_SOURCES`, and a names-suite
  case for the five new foundation words.
- Three native fixtures under `test/e2e/fixtures/ordering/` in the self-hosted
  e2e harness:
  - `operators.brp`: each operator on Int and Float at concrete types and
    through `T: Orderable`, including NaN and `-0.0 <= 0.0`; an override
    oracle that distinguishes dispatch from defaults and negation; an
    Orderable-only opaque type.
  - `order.brp`: impure operands evaluated once, left then right.
  - `nesting.brp`: 64 grouped comparisons, compared with ordinary calls. The
    emitted C has a maximum parenthesis depth of 4 and brace depth of 3.
- Each oracle was proved by breaking the behavior it protects:
  - **A.** Dispatching `>` to `greater_than_or_equal` failed the check
    suite's member test and changed the native row `3 > 3` to 1. Changing
    the `=<` help failed its lexer test. Rendering Orderable's malformed-trait
    text with Equatable's wording failed both malformed-trait tests.
  - **B.** Swapping the `<=` and `>=` words in admission failed the member
    test and changed the native rows. Reverting the trait name in the
    missing-implementation message failed the aggregate and Orderable-only
    tests.
  - **C.** Swapping operand order made `order.brp` print `right` before
    `left` and exit 0.
  - **D.** Dropping the `>=` parser mapping and the `<` lexer case failed 4 of
    7 lexer tests and 7 of 8 parser tests.
  - **E.** Removing comparison from the parenthesized statement path failed
    the entry-path and chain tests.
  - **Redirect.** Dispatching `<` to `greater_than` also failed the redirect
    test, whose decoys are a free `less_than` and an unrelated trait's
    `less_than` in the user module.

## Milestones

1. Operators (this step), with matched frozen-input cost in
   [the benchmark summary](../benchmarks/results/blorp2-ordering-operators-2026-10-29.md).
2. Seed: CI publishes a seed from the passing push; then pin it.
3. Migration: rewrite the compiler, library and test calls to the operators,
   folding `.less_than(...).not()` into `>=` only for Int, never Float, and
   update the compiler-source subset in [AGENTS.md](AGENTS.md).
