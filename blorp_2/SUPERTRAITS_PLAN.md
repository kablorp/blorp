# Supertraits

Status: approved 2026-10-30, with the owner decisions below accepted as
recommended. Milestone 1 is implemented; milestones 2 and 3 are not started.
[The traits plan](TRAITS_PLAN.md) deferred supertraits from its first
increment. This plan adds them so that the arithmetic traits can be
small single-operator traits composed into named bundles, and so that an
`Orderable` bound can provide `==`. The legacy compiler is the precedent; the
[deviations](#deviations-from-the-legacy-compiler) section lists where this
plan differs and why.

## Problem

A trait cannot require another trait. A header with a supertrait fails at the
second name with a message that does not mention supertraits:

```blorp
trait Ordered: Equatable:
    pure func less_than(left: Self, right: Self) -> Bool
-- 1:16: error: expected a newline after the trait header
-- help: put each method signature on its own indented line
```

A function that needs several traits must name each one at every use, and no
bound implies another. Inside `[T: Orderable]`, `left == right` reports
"type does not satisfy the required trait bound", and the check suite pins that
in `test_orderable_bound_does_not_grant_equality`. Without supertraits, the
arithmetic plan has to choose between two poor options. One is a single large
`Numeric` trait, which no type can implement in part. The other is repeating
bounds such as `T: Addable + Subtractable + Multipliable + Divisible` on every
generic numeric function.

## Language rules

### Declaration

A trait header may name supertraits after its colon, joined with `+` as in a
type-parameter bound. A trait with supertraits takes one of two forms: a method
block after a second colon, or no body at all. A trait with no body is a
bundle:

```blorp
trait Ordered: Equatable:
    pure func less_than(left: Self, right: Self) -> Bool
    pure func at_most(left: Self, right: Self) -> Bool:
        -- A default body may call a supertrait method on Self.
        or(less_than(left, right), equals(left, right))

trait Ring: Addable + Multipliable
```

- A supertrait is a visible trait, written the way a bound is written,
  including `alias.Trait`. Resolution reuses `resolve_trait`.
- Naming the same supertrait twice is accepted, as a repeated bound is today.
  A diamond, where two supertraits share a supertrait, is also accepted.
- A bundle may be the last line of a file, as a bodyless implementation can.
- Traits stay parameterless. A trait with neither methods nor supertraits is
  rejected as it is today.
- A public trait may not name a private supertrait. Code outside the module
  could then bound by the trait but never implement it. Trait bounds have no
  such access check today; this rule is new for supertraits, and the bound gap
  stays out of scope.

### Entailment

A bound `T: Sub` provides every trait in `Sub`'s transitive supertrait
closure. Inside `[T: Ordered]`, all of these check:
- `left == right` and `left.equals(right)`;
- calls to supertrait methods on `Self` in a default body;
- the same calls in an implementation whose receiver parameters carry the
  bound.

A supertrait method is still selected by name and must be visible where it is
called, as any trait method must. Operators select their canonical member
without a visible name. When two visible traits in the closure declare the
same method name, the existing `DifferentMethodFamilies` rejection applies; a
subtrait may use a name its supertrait also uses. Entailment runs one way
only: `[T: Equatable]` does not provide `<` or `less_than`.

### Implementation obligations

Implementing a trait requires an implementation of each direct supertrait for
the same receiver. That implementation may be authored, or automatic as derived
equality is. A supertrait implementation is never implied:

```blorp
record Version { major: Int, minor: Int }

-- Version's equality is automatic, so this is accepted.
implements Ordered for Version:
    pure func less_than(left: Version, right: Version) -> Bool:
        if left.major == right.major:
            left.minor < right.minor
        else:
            left.major < right.major

-- A bundle has no methods, so its implementation has no body.
implements Ring for Int
```

A generic receiver also needs its bounds to line up. At each receiver
position, every bound that the supertrait's implementation requires must be
entailed by a bound that the subtrait's implementation declares. For example,
`implements Ordered for Box[T: Ordered]` is accepted when Box's automatic
equality needs `T: Equatable`, because `T: Ordered` entails `T: Equatable`.
The same receiver is rejected when Box's Equatable implementation is bounded
by `T: Hashable`, because `Box[X]` could then be Ordered without being
Equatable.

An implementation defines only its own trait's methods. Defining a supertrait
method there is already rejected as an unknown method. It now gets its own
message and help, which name the trait that owns the method.

### Diagnostics

Every new rejection has a help line. Spans are at the named supertrait, or at
the implementation's trait name for an obligation; the parser's two header
errors are at the token where the colon or line end belongs. When a check
rejects several things, the first error stops it, so a wrapped error is
replaced, not attached.

| Case | Message | Help |
| --- | --- | --- |
| Unknown or non-trait name | `supertrait requires a visible trait` | `import a parameterless trait and name it after ':' or '+'` |
| `trait A: A`, or a longer cycle | `trait inheritance cycle: A -> B -> A` | `remove one of these supertraits` |
| Public trait, private supertrait | existing `B is private but appears in public declaration A` | existing `make B public, or make A private` |
| No supertrait implementation for the head | `implementing Ordered for Version requires an implementation of Equatable` | `add implements Equatable for Version` |
| The head's automatic equality was rejected for a member | same message | the existing `EqualityMemberUnsupported` help, at the implementation |
| The head's automatic equality was removed as not provably finite | same message | `Box's automatic equality cannot be proved finite; write implements Equatable for Box` |
| A receiver bound is not entailed | `implementing Ordered for Box requires T: Equatable` | `add Equatable, or a trait that requires it, to T's bounds` |
| Supertrait method in a subtrait implementation | `equals belongs to supertrait Equatable` | `define it in implements Equatable for Version` |
| `trait A: B` followed by an indented block and no second colon | `expected ':' before the trait's methods` | `write trait A: B: and indent the methods below it` |
| `trait A: B C`, another token after the supertraits | `expected ':' or a newline after the supertraits` | `add ':' before indented methods, or end the line for a trait without methods` |

The obligation messages name the receiver by its written type name, without a
module alias.

Canonical Equatable must declare no supertraits. The message is `canonical
Equatable cannot declare supertraits`, and the help is `remove them; automatic
equality requires no other trait`. Automatic implementations are created
without asking for other traits, so a supertrait on Equatable would make every
derived record fail its obligation. Canonical Orderable may declare
supertraits.

The obligation check runs at the end of Check, so a body error can come first.
Suppose `Version` has no equality and a body writes `a == b` on it: that body
reports "receiver does not implement Equatable" before the implementation's
obligation error. This is accepted for the soundness reason given under
Obligations.

## Deviations from the legacy compiler

| Legacy | This plan | Reason |
| --- | --- | --- |
| The missing-supertrait error has no help line | The help names the implementation or bound to add | Rule 6: every error teaches the fix. |
| An implementation's methods that its trait does not declare are ignored; the library adds `__numeric_marker` methods to give bundle implementations a body | Blorp 2 already rejects them; the bundle form is a bodyless `implements Ring for Int` | Blorp 2 already supports implementations made only of defaults. |
| Builtin trait topology is written twice, in `traits.brp` and in `builtins.brp` | The library declaration is the only source | One fact, one owner. |
| Builtin facts supply `Integer` and `FloatingPoint`, with no `implements` | Every implementation is written | No compiler-owned implementations are needed. |
| Method lookup takes the first match in the trait, then its supertraits in written order | Blorp 2 already rejects a use when two visible families share the name (`DifferentMethodFamilies`) | Existing Blorp 2 rule; the choice never depends on declaration order. |
| A cycle or duplicate supertrait is reported in a separate header phase | Cycles are rejected in trait acceptance; duplicates are accepted, as they are in bounds | No phase is added, and no rule is added that bounds do not have. |

The legacy grammar, transitive entailment, explicit supertrait implementations,
diamond acceptance and cycle reporting stay as they are.

## Compiler implementation

All semantics live in Check. Specialize, Lower, Own, Verify and Emit need no
change. A supertrait call in a bounded body is an ordinary
`TraitMethod(member, T)`. Once Check guarantees the supertrait
implementation, `selected_method_body` finds it by member and receiver head
after grounding.

- **Parse** (`consume_trait`, `src/parse/parse.brp`):
  - After the first colon, a newline starts the method block as it does today.
  - Otherwise `consume_parameter_bounds` reads the supertraits. Then either
    `:` NEWLINE INDENT methods follows, or a newline or end of input ends a
    bundle.
  - `ParsedTrait` and `TraitRow` gain `supertraits: List[TypeSyntax]`, empty
    for a plain trait. `ParsedTrait` is built only in `consume_trait`.
  - The header span still ends at the first colon.
  - A missing second colon is reported at the newline before the indented
    block; another token after the supertraits gets its own diagnostic.
- **Acceptance** (`accept_trait`, `src/check/traits.brp`):
  - Resolve each supertrait with `resolve_trait` in the trait's module, check
    its visibility there, and record `AcceptedTrait.supertraits:
    List[LocatedTrait]` with the direct supertraits only. The closure is not
    stored, because it would repeat facts the direct lists already hold.
  - After every trait is accepted and the canonical traits are admitted,
    `accept_trait_contracts` rejects cycles. From each trait in order, a walk
    up its supertraits reports an edge back to that trait at the edge, with
    the walk as the path; a trait already on the walk ends it, because that
    cycle is reported from its own traits.
- **Entailment:**
  - Add `entails(traits, held, required) -> Bool`. It is true when `held` is
    `required`, or when `required` is reachable from `held` through
    `supertraits`. Acyclicity is established before any proof runs, so the
    walk terminates.
  - `prove_trait`'s rigid-parameter case (`traits.brp:423`) is the only place
    an assumption is compared with a required trait. It calls `entails` in
    place of the trait-number comparison.
  - `signature.requirements` keeps the bounds as written, so recursion
    analysis and call-site proofs are unchanged.
- **Obligations:**
  - A new pass, `validate_supertrait_implementations`, works position by
    position, because implementation bounds are positional lists with no
    parameter identities (`ImplementationHeader.parameter_bounds`,
    `src/check/model.brp`). For each implementation of `Sub` for a head, and
    each direct supertrait `S`, it requires `family_for(S, head)`. At every
    receiver position, each bound of that family must be entailed by some
    bound of the `Sub` implementation.
  - Receivers are always complete families of fresh parameters, so this
    matches what proving `S` on the receiver would decide, and it mints no
    identities.
  - The pass lives in its own module, `src/check/supertraits.brp`, and takes
    `FinalTraits`: an opaque type in `recursion.brp` that only
    `finalize_trait_instances` builds, holding the surviving implementations
    and the removed automatic equalities. Running the pass before
    finalization therefore does not compile. It runs there, not after
    `validate_implementations`, for two reasons:
    - Running it before `prepare_equality_availability` would reject a
      subtrait implementation whose supertrait is automatic equality.
    - `finalize_trait_instances` can remove a derived equality that a generic
      use cannot instantiate finitely. A body that uses `==` through
      entailment calls the Equatable member on a parameter.
      `unavailable_named` and `unavailable_goal` follow only the written
      `Ordered` bound, so the finalizer cannot see that use.
  - Checking against the final implementations establishes the invariant
    that Specialize relies on: every implementation of `Sub` for a head comes
    with an implementation of each supertrait for that head, whose bounds the
    `Sub` bounds entail.
- **Errors** (`src/check/errors.brp`, `render.brp`):
  - Add `SupertraitUnknown`, `SupertraitCycle(List[TraitId])`,
    `SupertraitNotImplemented(TraitId, TraitId, ParsedReceiverHead, AbsentSupertrait)`,
    `SupertraitBoundNotEntailed(TraitId, TraitId, WrittenName, ParsedReceiverHead)`,
    `SupertraitMethodInImplementation(NameId, TraitId, ParsedReceiverHead)` and
    `CanonicalEquatableSupertraits`. The written receiver names the type in
    each message.
  - `AbsentSupertrait` is `NeverImplemented`,
    `AutomaticEqualityRejected(EqualityMember)` or
    `AutomaticEqualityNotFinite`. Render has no availability, so the pass
    records which case applies; the member case keeps the existing member
    note.
  - `SupertraitBoundNotEntailed` carries the receiver parameter's written
    name, which the pass reads from the implementation's header row.
    `AcceptedImplementation` keeps no parameter names, and an unbounded
    parameter has no bound span.
  - A finalizer-removed equality records no `EqualityUnavailable` cause, so
    `FinalTraits` carries the aggregates it removed, and the pass records
    `AutomaticEqualityNotFinite` for a head among them.
  - A private supertrait reuses `PrivateTypeInPublicDeclaration`.
- **Grammar:**
  - `trait_declaration` in `grammar.ebnf` adds the supertrait and bundle
    forms, and its comment states the rules above.
  - Matching cases go in `test/test_grammar/`. That suite is deferred, so the
    active parse suite carries the evidence.

## Tests

The existing trait suites under `test/unit/test_check/` are deferred and use
legacy syntax. This work instead adds active suites, registered in the
Makefile's `TARGET_COMPONENT_SOURCES` and modelled on
`test_check/test_ordering_operators.brp`:

- `test_parse/test_supertraits.brp`:
  - the header forms, including a bundle on the last line of a file;
  - qualified names and the span of each supertrait;
  - the missing-second-colon diagnostic and the `trait A:` with no body
    diagnostic.
- `test_check/test_supertraits.brp`:
  - each diagnostic in the table, with message, help and span;
  - entailment of a method call, an operator and a default body, transitive
    entailment through three levels, and a diamond;
  - the reverse direction: `[T: Equatable]` using `<` is rejected;
  - `DifferentMethodFamilies` when the closure's traits, declared in two
    modules, share a visible method name;
  - generic obligations, both entailed and rejected, and obligations met by
    automatic equality.
- Native fixtures under `test/e2e/fixtures/supertraits/` in the self-hosted
  harness, each with exact stdout and allocations:
  - `entailment.brp`: `==` and a supertrait method through `[T: Ordered]`,
    on Int, on a record with automatic equality, and on a written Equatable
    whose output tells dispatch apart from the derived body.
  - `bundle.brp`: a bodyless `Ring` bundle over Int and over a user record,
    used through `[T: Ring]` with methods from both supertraits.
  - `generic_receiver.brp`: `implements Ordered for Box[T: Ordered]`, with
    `==` on `Box[Box[Int]]`.

Each oracle is proved by breaking what it protects, and the change reports
which tests each mutation broke:

- **Entailment.** Restoring the trait-number comparison fails every
  entailment test, and the native fixtures no longer compile. Reversing the
  walk inside `entails` fails the reverse-direction test.
- **Obligation.** Skipping the pass makes the missing-implementation and
  unentailed-bound tests accept.
  - `validate_finite_declarations` rejects declarations that reinstantiate
    themselves, so no source program known today reaches the finalizer's
    removal. The placement test follows the precedent in
    `test_generic_equality_finite_uses.brp`, which injects the unavailable
    set: it marks Box unavailable, runs the finalizer, and expects the
    obligation pass to reject `implements Ordered for Box[T: Ordered]`.
  - Moving the pass before finalization does not compile, because only
    `finalize_trait_instances` builds the `FinalTraits` it takes. The
    equivalent mutation, a finalizer that publishes the implementations it
    was given, fails that test.
- **Cycles.** Removing cycle detection fails the self-cycle and
  three-trait-cycle tests, within the suite's timeout if entailment then loops.
- **Canonical root.** Accepting a supertrait on canonical Equatable fails its
  admission test.

The results, test by test, are in
[the cost summary](../benchmarks/results/blorp2-supertraits-2026-10-30.md#mutation-probes).

## Cost

Nothing in the self-compilation input declares a supertrait until milestone
3, when the library does. Until then, self-compilation pays only for:
- an empty supertrait list per trait;
- the obligation pass over its implementations;
- the entailment fallback when a direct comparison fails.

Ceilings, measured with the matched frozen-input recipe and recorded in a
`benchmarks/results/` summary:

- allocations at most +0.05%;
- retired instructions at most +0.3%;
- at most 300 production lines, with test lines reported separately. The
  owner raised this to 310 on 2026-10-30, after review cuts reached 316 and the
  obligation message dropped its spelling-based article.

If the obligation pass costs more than the allocation ceiling, index
implementations by trait first; do not skip implementations. Milestone 3
changes the self-compiled library, so it is measured again with the same
ceilings in its own summary.

## Milestones

1. **Supertraits.** The rules, implementation, tests and documentation above.
   The documentation updates are:
   - `README.md`: the Concrete traits section and the list of rejected trait
     forms;
   - `TRAITS_PLAN.md:68`;
   - `grammar.ebnf`;
   - the deferred-trait-forms sentence in `docs/GUIDE.md:129`.
2. **Seed.** CI publishes a seed from the passing push, then the pin moves to
   it. The seed compiles the standard library, so the library cannot declare
   a supertrait before this.
3. **`Orderable: Equatable`:**
   - Move canonical Equatable into `_base.brp` beside Orderable, because
     `_base` imports nothing and cannot import `traits.brp`.
   - Declare `trait Orderable: Equatable`.
   - Delete the now-empty `traits.brp`, and import Equatable from `_base` in
     `int`, `float`, `string`, `list` and `prelude`.
   - Invert `test_orderable_bound_does_not_grant_equality` and
     `test_orderable_only_type_rejects_equality`.
   - Give the Orderable-only opaque type in
     `test/e2e/fixtures/ordering/operators.brp` a written Equatable.
   - Remove "An `Orderable` bound does not provide `==`" from the README, the
     ordering plan and `docs/GUIDE.md:16`.

   NaN still compares unequal to itself and unordered with everything. The
   supertrait requires an Equatable implementation, not agreement between the
   two traits.

The arithmetic plan builds on milestone 1: one trait per operator, composed
into named bundles.

## Owner decisions

All three were accepted on 2026-10-30.

1. **Supertrait implementations are written explicitly.** The alternative is
   that any type implementing all of a bundle's supertraits satisfies the
   bundle. That saves `implements Ring for Int`, but it would make a bundle a
   structural alias while every other trait is nominal. An implementation
   would also no longer record that its author meant the type to be a Ring.
2. **Bodyless bundles are allowed,** as in the legacy `Numeric`.
3. **`Orderable: Equatable` lands in milestone 3.** The alternative keeps
   ordering and equality independent, so every sort or search that also
   deduplicates needs `T: Orderable + Equatable`.
