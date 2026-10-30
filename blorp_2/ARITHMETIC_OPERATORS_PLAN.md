# Arithmetic operators

Status: approved 2026-10-30, with the owner decisions below accepted as
recommended; milestone 1 implemented. This plan mirrors [the ordering
operators plan](ORDERING_OPERATORS_PLAN.md), whose rules apply unless a
section below says otherwise. It builds on [supertraits](SUPERTRAITS_PLAN.md) milestone 1.
The legacy compiler is the precedent; the
[deviations](#deviations-from-the-legacy-compiler) section lists where this
plan differs and why.

## Problem and scope

Arithmetic is written as calls, `total.add(price.multiply(count))`. Neither
`a - 1` nor `-x` lexes. The lexer reads every `-` that is not `->` or `--`
as the sign of a numeric literal, so a `-` not followed by a digit is an error:

```blorp
pure func gap(low: Int, high: Int) -> Int:
    high - low
-- 2:10: error: expected decimal digits immediately after '-'
```

Three more things are rejected today:
- `%` is an unsupported character;
- a `+` before a digit is "source numeric literals cannot start with '+'";
- any other `+` after an operand is "'+' is only supported between trait
  bounds".

This plan adds six compiler-owned operators, each dispatched through a
canonical single-method trait:

| Syntax | Trait | Selected member |
| --- | --- | --- |
| `a + b` | `Addable` | `add(left: Self, right: Self) -> Self` |
| `a - b` | `Subtractable` | `subtract(left: Self, right: Self) -> Self` |
| `a * b` | `Multipliable` | `multiply(left: Self, right: Self) -> Self` |
| `a / b` | `Divisible` | `divide(left: Self, right: Self) -> Self` |
| `a % b` | `Modulable` | `remainder(left: Self, right: Self) -> Self` |
| `-a` | `Negatable` | `negate(value: Self) -> Self` |

Owner decision (2026-10-29): there are no checked operators. The operators
keep the language's total semantics, which the library already implements:
- Int add, subtract, multiply and negate wrap at the signed 64-bit limits.
- Int `/` truncates toward zero, and `%` takes the dividend's sign.
- Int `/` and `%` by zero give 0. `INT_MIN / -1` is `INT_MIN`, and
  `INT_MIN % -1` is 0.
- Float follows IEEE 754 binary64, except that `/` and `%` by zero give `0.0`,
  as `float.divide` and `float.remainder` do today.

Out of scope, each a separate later change:
- compound assignment (`+=`);
- an expression continuing onto the next line after a trailing operator;
- numeric bundles such as `Numeric`, and `zero()`/`one()`. A trait method's
  first parameter must be `Self`, so a nullary `zero()` needs its own design;
- `+` on List;
- power, floor division and bitwise operators;
- mixed-type arithmetic;
- checked arithmetic, which would stay ordinary methods if it is ever added.

## Language rules

The ordering plan's rules apply with the arithmetic traits in place of
Orderable:
- The prelude's binding selects each trait. A user trait or function spelled
  `Addable` or `add` cannot redirect `+`.
- Each operator invokes its own member. `a - b` is never `a + -b`.
- Both operands of a binary operator share `Self`, and the result is `Self`.
  Operands go through ordinary inference, purity and bounds, and are
  evaluated once, left then right.
- Without a canonical trait, an operator reports at its token:
  **"arithmetic operator '+' requires the canonical Addable trait"**, help
  **"select Addable in the configured prelude"**. Each operator names its own
  trait.

**Admission.** A canonical arithmetic trait's abstract method must be its
only abstract method, pure, with its row's signature. Otherwise it reports
**"canonical Addable requires pure add(Self, Self) -> Self as its sole abstract
method"**, help **"keep add abstract; other pure methods require default
bodies"**, at the trait's name. Negatable's text reads `negate(Self) -> Self`.
This matches both precedents, which admit defaults and supertraits beside the
abstract member; the library's arithmetic traits declare neither.

**Never derived.** A type without an implementation reports the existing
**"receiver does not implement Addable"**. There is no implicit conversion:
`1 + 2.0` is a type mismatch, as `add(1, 2.0)` is today. When one operand of
`+` is a String and the other is not, the mismatch adds the help **"use
interpolation, such as \"n=${value}\", to join a value to text"**.

### Grammar

Arithmetic sits between ranges and postfix applications, the place
`docs/GRAMMAR.md`'s precedence table gives it. `blorp_2/grammar.ebnf` gains:

```ebnf
range_expr          = additive_expr [ spaces ".." spaces additive_expr ] ;
additive_expr       = multiplicative_expr
                      { spaces additive_op spaces multiplicative_expr } ;
multiplicative_expr = prefix_expr
                      { spaces multiplicative_op spaces prefix_expr } ;
prefix_expr         = "-" prefix_expr | operand ;
additive_op         = "+" | "-" ;
multiplicative_op   = "*" | "/" | "%" ;
```

- **Associativity.** `+ -` and `* / %` are left-associative: `a - b - c` is
  `(a - b) - c`. The parser reads each level with a loop, as
  `consume_logical_rest` does, not by recursion.
- **Prefix minus.** It binds tighter than `*` and looser than postfix calls,
  so `-x.abs()` is `-(x.abs())` and `-2 * 3` is `(-2) * 3`.
- **Entry paths.** Every entry path gains the two levels, including the
  parenthesized statement path that the equality and ordering plans had to
  fix.
- **Newlines.** As for comparisons, a newline after an operator ends the
  expression, and its operand is missing. Newlines continue only inside
  brackets, so a long expression is wrapped in parentheses.
- **`not`.** `not` cannot be an operand of an arithmetic operator.
  `a + not b` reports **"'not' cannot be an operand of '+'"**, help
  **"parenthesize the negation, or move it outside the arithmetic"**,
  following the comparison and range messages.

### Minus, plus and negative literals

The lexer stops attaching a sign to numbers:
- a `-` that is not `->` or `--` is always `Minus`;
- `+` is always `Plus`;
- the sign inside an exponent, as in `1e-5` and `1e+5`, stays part of the
  number;
- `%` is `Percent`.

`Star` and `Slash` already exist. The parser folds a prefix minus applied
directly to an integer or float literal token into one negative literal:

```blorp
INT_MIN: Int = -9223372036854775808     -- one literal; the range check sees the sign
offset = position-1                     -- subtraction, whatever the spacing
values = [1, -2, -0.0]                  -- -0.0 stays negative zero
twice = -(-x)                           -- negate applied twice
```

- **Why fold.** Folding keeps the literal range check, `-0.0` and negative
  literal constants working as they do today. The fold is a grammar rule
  (prefix minus whose operand is a literal token) and does not depend on
  spacing. A future numeric literal pattern must fold the same way.
- **Spacing.** It no longer matters: `a-1`, `a -1`, `a - 1`, `a+1` and `a +1`
  are ordinary binary expressions. Today `a-1` and `a -1` lex as `a`
  followed by the literal `-1`, and `a+1` is a lexer error.
- **Prefix plus.** There is none. A `+` in operand position reports **"Blorp
  has no prefix '+'"**, help **"remove the '+'; values are positive unless
  negated"**.
- **Comments.** `--` directly after a value-ending token (a name, a literal,
  `)`, `]` or `}`) is rejected: `a--1` reports **"'--' directly after a value
  starts a comment"**, help **"write a - -1 to subtract a negative number, or
  add a space before the comment"**. Without this rule, `a--1` would silently
  compile as `a`. A comment after `(`, `[`, `,` or an operator, such as
  `one(-- argument`, which `test/test_grammar/test_trivia.brp` covers, stays
  valid.
- **Literal followed by a call.** A folded negative literal followed by a
  postfix application is rejected. The fold would read `-2.abs()` as
  `(-2).abs()`, while the precedence rule reads it as `-(2.abs())`.
  - The message is **"write (-2).abs() or -(2.abs()) to say which is meant"**,
    help **"prefix '-' applies after method calls"**, at the minus sign.
  - Readers split on its meaning, and both explicit forms are short.
  - Two fixtures use the form today and become `(-7).to_string()`:
    `test/e2e/fixtures/mortal_string/alias.brp` and `minimum.brp`.

### Spellings from other languages

| Input | Message | Help |
| --- | --- | --- |
| `x += 1`, and likewise `-=`, `*=`, `%=` | `'+=' is not supported yet`, naming the spelling written | `write x = x + 1` |
| `x /= 2` | `'/=' is not supported yet` | `write x = x / 2, or write != for inequality` |
| `a ** b` | `'**' is not an operator` | `multiply, or call a power function` |
| `a // b` | `'//' is not an operator` | `comments start with --; write a / b to divide` |

Each is rejected in the lexer, where both bytes are known, with a span over
both, as `=>`, `=<` and `<>` are.

## Library

`_base.brp` declares the six traits beside Orderable. `_base` owns the
canonical prelude traits and imports nothing:

```blorp
trait Addable:
    pure func add(left: Self, right: Self) -> Self
-- ... Subtractable, Multipliable, Divisible, Modulable
trait Negatable:
    pure func negate(value: Self) -> Self
```

The free functions become implementations. A trait method family conflicts
with a free function of the same name (`FamilyFunctionConflict`, callables.brp),
and `string.brp` sees Int's methods, so every free `add` that is visible through
the prelude changes in the same step:

| Type | Implements | Notes |
| --- | --- | --- |
| Int | all six | `negate` is `subtract(0, value)`, which wraps `INT_MIN` to itself |
| Float | all six | `negate` is `multiply(value, -1.0)`: exact, except that a NaN's sign bit may stay unchanged |
| String | Addable | `"a" + "b"` concatenates through today's `string.add` |

Neither negate needs a new builtin, so the library change does not wait on a
seed. Calls written `a.add(b)`, `add(a, b)` and `int: add` keep working as
trait-method calls, as `less_than` does after the ordering change.

**String concatenation cost.** A direct call to the builtin `add` is lowered to
`RuntimeTarget(StringConcat)`, which reuses its left operand in place. A call
through `TraitMethod` specializes to a call of the wrapper function instead.
String joins are common in compiler source, so milestone 1 reads the
generated C for a String add before and after the change. If in-place reuse
is lost, milestone 1 also makes an implementation method whose body is a
single builtin specialize to that builtin's runtime target, as a direct call
does.

## Compiler implementation

- **Syntax.** One `ArithmeticOperator` union (`Add | Subtract | Multiply |
  Divide | Remainder`), an `ArithmeticExpression(op, span, left, right)`, and
  a `NegationExpression(span, operand)`. Negation is unary and has its own
  member shape, so it is not a sixth binary case.
- **Lexer.**
  - `Minus`, `Plus` and `Percent`, and the three two-byte rejections.
  - The comment rule.
  - `-` and `+` no longer start numbers, so `separated_minus` and `plus_sign`
    are removed.
- **Parser.**
  - Additive and multiplicative loops between range and operand, with the
    same `inline`, `ending` and `owed` handling as comparison, on both entry
    paths.
  - Prefix minus, with the literal fold, the postfix rejection and the
    prefix-plus rejection.
  - The `'+' is only supported between trait bounds` error is removed.
- **Canonical contracts.**
  - Six foundation trait words and six member words.
  - `CanonicalContracts` gains one optional `CanonicalOperation` per
    operator: an opaque record holding the member's `TraitMethodId`. Each
    arithmetic trait has one abstract member, so one record shape serves all
    six.
  - `CanonicalFamily` gains `ArithmeticFamily(ArithmeticTrait)`.
    `ArithmeticTrait` names the six traits once, and render spells each.
  - `sole_abstract` and `default_member` take the expected member shape,
    `(Self, Self) -> Bool`, `(Self, Self) -> Self` or `(Self) -> Self`, in
    place of their Bool type.
  - `accept_trait_contracts` designates each canonical trait itself from
    `parsed` and `namespace`, rather than taking one positional option per
    trait. Its test callers, `test/unit/input.brp` and
    `test_check/test_trait_designation.brp`, change with it.
- **Dispatch.** One `arithmetic_contract` selects the member and enters the
  existing checked trait-call path, as `comparison_contract` does; negation
  is a one-operand call. There is no new checked form, ownership rule or
  emission case.
- **Depth.** `+` is the first binary operator that chains through Check,
  Specialize, Own and Emit, since comparisons do not chain. A 2,000-term sum
  must compile and run natively. A recursive consumer that overflows on it is
  made iterative in this change, as interpolation was bounded.
- **Constants.** Constant initializers reject calls, so `A: Int = 1 + 2` is
  rejected, and the message changes from "calls" to "calls and operators". A
  negative literal constant is still a literal and is accepted.

The pinned seed predates the operators, so compiler and library source keep
writing calls until the seed is rotated.

## Deviations from the legacy compiler

| Legacy | This plan | Reason |
| --- | --- | --- |
| `List + List` concatenates | Out of scope; List keeps `concat` | No user asked for it, and `concat` is established. Adding it later is cheap. |
| `+=`, `-=`, `*=`, `/=` | Rejected with a teaching message | One change per change: a statement form with its own rules. |
| `Numeric`, `Integer` and `FloatingPoint` bundles, the last two supplied as builtin facts | No bundles yet | `zero()` and `one()` need nullary trait methods first. Bundles are written when a consumer exists. |
| Unary minus on a literal is a typechecker special case | The parser folds a literal | The sign belongs to the literal's syntax, and the range check needs it. |
| `-2.abs()` parses silently | Rejected, showing both explicit forms | Readers split on its meaning. |
| Float `/` by zero gives IEEE infinity, contrary to the guide | `0.0`, as Blorp 2's library already does | Existing Blorp 2 rule: no runtime surprises. |

The trait names, member names, single-member traits and homogeneous `Self`
operands follow legacy.

## Tests

The new suites are `test_arithmetic_operators.brp` in lex, parse and check,
all registered in `TARGET_COMPONENT_SOURCES`, plus a names-suite case for the
twelve foundation words:
- **Lex:**
  - `a-1`, `a -1`, `a - 1`, `a+1` and `a +1` give binary tokens;
  - `->` and `--` comments are unchanged;
  - `%` lexes, and `1e+5` and `1e-5` stay single numbers;
  - the `a--1` and two-byte rejections, and `one(-- argument` still a comment.
- **Parse:**
  - precedence and associativity for every pair of levels, including `not`,
    comparison and ranges;
  - both entry paths;
  - the literal fold for `INT_MIN`, `-0.0`, `-(1)` and `- 1`;
  - the postfix and prefix-plus rejections;
  - a newline after an operator, rejected;
  - `a + not b`.
- **Check:**
  - member dispatch for each operator;
  - no redirection by decoys, a free `add` and a user trait's `add`;
  - admission of each malformed canonical trait;
  - a missing canonical trait, and a missing implementation;
  - `1 + 2.0`, and the String interpolation help;
  - a constant initializer.

Native fixtures under `test/e2e/fixtures/arithmetic/` run in the self-hosted
harness:
- `operators.brp`:
  - each operator on Int and Float at concrete types and through bounds;
  - the wrap, zero-divisor, `INT_MIN / -1` and `-0.0` rows;
  - `"a" + "b"`;
  - a user record whose `subtract` prints a marker, which tells dispatch apart
    from any rewrite.
- `order.brp`: impure operands are evaluated once, left then right.
- `nesting.brp`: 64 mixed-precedence expressions compared with the equivalent
  calls, with a bound on emitted C nesting, as for ordering.
- `long_sum.brp`: a 2,000-term Int sum and a 2,000-part String join.

These tests change with the new rules:
- the separated-minus and plus-sign cases in `test_lex/test_lex.brp`;
- the `+` case in `test_parse/test_traits.brp`;
- the deferred `test/test_grammar/test_conformance.brp` and `test_floats.brp`;
- `test/e2e/test_frontend.brp`;
- the two `mortal_string` fixtures.

Each oracle is proved by breaking what it protects, and the change reports
which tests each mutation broke:

| Mutation | Must fail |
| --- | --- |
| `-` dispatched to `add`; `%` to `divide`; `negate` to `subtract` | the check member test, and the native rows |
| `+` and `*` precedence swapped; prefix `-` bound above postfix | the parse precedence tests, and the `nesting.brp` comparisons |
| `-` right-associative | the parse associativity test, and the native `a - b - c` row |
| the literal fold dropped | the `INT_MIN` constant and parse-shape tests; the `-0.0` native row cannot detect it, because the negated `0.0` is also `-0.0` |
| the postfix rejection removed | its parse test |
| one entry path removed | the entry-path test |
| operand order swapped | `order.brp` |

## Cost

Ceilings, measured with the matched frozen-input recipe:

| Milestone | Retired instructions | Allocations | Production lines |
| --- | --- | --- | --- |
| 1: library traits | +0.3% | +0.1% | 60 |
| 3: operators | +0.8% | +0.1% | 450 |

Milestone 1 includes any String specialization it needs. Milestone 3 touches
every `-` in the lexer and adds two parser levels per operand. Ordering's one
level cost +0.33%, so its instruction ceiling is set with that in mind.
Production lines count gross additions; net lines and test lines are reported
separately.

**The input effect is the binding cost.** The frozen recipe compiles the same
input with both compilers, so it cannot see what a library or source change
costs every compilation that reads it. Milestone 1 met its frozen-recipe
ceilings, at +0.04% instructions and no allocation change, but the same
compiler compiling the milestone's own `blorp_2` against its parent cost +5.0%
instructions and +1.4% allocations: each arithmetic UFCS call became a
trait-method call, and Check scanned every implementation row per call. The
resolution fix,
[e594b4d72](../benchmarks/results/blorp2-trait-resolution-cost-2026-10-30.md),
brought that to +0.74% instructions and +0.27% allocations. Each later
milestone that changes what compiler source calls or how calls resolve also
measures the input effect: the candidate compiler on the candidate `blorp_2`
against the same compiler on its parent's `blorp_2`.

## Milestones

1. **Library traits.**
   - The six traits in `_base`, and the Int, Float and String implementations
     in place of the free functions.
   - Read the generated C for an Int add and a String add, before and after.
   - Verify that alias calls such as `IntOps.add(...)` and builtin-bodied
     methods returning `Self` still check.
2. **Contract refactor.** Member checks take a shape, and designation moves
   into `accept_trait_contracts`. Compiler output stays byte-identical.
3. **Operators.**
   - Precondition: remeasure milestone 1's input effect on the current main
     and record it beside this milestone's frozen-recipe numbers.
   - Lexer, parser, dispatch, diagnostics and tests, as above.
   - Docs:
     - `grammar.ebnf`: the literal, range, precedence and comment
       (`trivia_line`, `line_comment`) rules;
     - the README's operator, signed-literal and comment sections;
     - `standard_library/README.md`;
     - the Blorp 2 notes in `docs/GUIDE.md`, including its comments section,
       and in `docs/GRAMMAR.md`.
4. **Seed.** CI publishes a seed from the passing push, and the pin moves to
   it.
5. **Migration.** Rewrite compiler, library and test calls to the operators,
   in one pass with the pending ordering migration, and update the
   compiler-source subset in `AGENTS.md`.
   - Precondition: remeasure the input effect first. The migration changes
     every arithmetic call site in compiler source, so its cost is the input
     effect, not the frozen-recipe change.

## Owner decisions

All five were accepted as recommended on 2026-10-30.

1. **Trait names.** Recommended: the legacy names, `Addable`,
   `Subtractable`, `Multipliable`, `Divisible`, `Modulable` and `Negatable`.
   `Modulable` names `%`, which is a truncated remainder rather than a
   modulo. The alternative is to rename it, for example to `Remaindered`, at
   the cost of differing from the legacy library and guide.
2. **String `+`.** Recommended: String implements Addable, so `"a" + "b"`
   works. String already names concatenation `add`, and a free `add` cannot
   sit beside the trait family. The alternative renames it `concat` and
   leaves `+` off String, so interpolation stays the one way to join text.
3. **Negative literals.** Recommended: the lexer always emits `Minus`, and
   the parser folds a prefix minus applied to a literal, rejecting a folded
   literal followed by a postfix call. The alternative keeps the sign in the
   lexer when `-` does not follow a value-ending token. `a -1` and `a - 1`
   would then still lex alike, but the lexer would need state about the
   previous token, and `-2.abs()` would silently mean `(-2).abs()`.
4. **Comment after a value.** Recommended: `--` directly after a name,
   literal or closing bracket is rejected, so `a--1` is not silently read as
   `a`. Comments after `(`, `,` or whitespace are unaffected. The alternative
   keeps today's rule and documents the hazard.
5. **Ordering migration.** Recommended: merge the pending ordering migration
   into milestone 5, so the compiler source changes in one pass.
