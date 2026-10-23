# Static traits, starting with Equatable

Status: T0 inference and T2 semantic instance identity complete; T1, T3–T5 remain
open, 2026-10-22. Original measurement baseline:
`02b13d25d04b7c5670cb94052ea9675cc9ba3428`. Nothing below claims that
traits are currently accepted by Blorp 2. Code marked **source** describes
the proposed input language; code marked **model sketch** describes compiler
data, not a second language or an additional runtime representation.

Completed T2 evidence is retained in the
[semantic instance identity report](../benchmarks/results/blorp2-semantic-instance-keys-2026-10-22.md).

This is the single plan for the open work. Delete completed milestone
instructions as they land; retain semantic rules in README/grammar and
measurements in benchmarks/results. Agent messages follow
[HANDOFF_SPEC](../docs/HANDOFF_SPEC.md); do not create a separate plan per worker.

## 1. Problem and agreed contract

Today Blorp 2 exposes concrete functions such as `int.equals` and has no
accepted trait declarations or bounds. Introducing equality must preserve
ordinary type inference, nominal identity, purity, imports and ownership.
It must not create a parallel call graph or carry trait machinery into
lowering, ownership, verification or C emission.

The owner has settled these semantics:

- Generic bodies may use only their declared bounds. Callers never infer
  missing bounds for a generic declaration.
- Records and unions, including fixed spellings and payload variants,
  automatically support canonical Equatable on use when their actual
  fields/payloads support it. No derive annotation is needed.
- An unused declaration containing a non-equatable field is legal.
  Attempted equality or use under an Equatable bound produces a checker error.
- A written implementation replaces automatic equality. Nested derived
  equality must call that implementation.
- Only records/unions receive automatic structural equality in this work.
  Primitives, Lists and opaque types need ordinary written implementations.
  Tuples and callable values receive no automatic implementation here.
- Use ordinary calls and UFCS. Operators, record shorthand and record
  destructuring are outside this work.

### First supported trait surface

Implement parameterless static traits with typed `Self`, pure methods,
ordinary defaults, function-parameter bounds and generic receiver
families. This permits small user-defined traits as well as canonical
Equatable; only the designated canonical identity enables automatic equality.
Every method must have a first parameter whose type is exactly `Self`.
Signatures may otherwise use currently supported ordinary types and `Self`,
except explicit top-level callable parameters. Defer those with exact help:
current CallableParameterId owns a FunctionId, which an abstract method lacks.
Passing equals as an ordinary function value is a different, supported T3 path;
it does not require generalizing callable formal ownership.
Bounds are supported on function type parameters and parameters introduced by
an implementation receiver. Record/union declaration bounds are deferred with
an exact unsupported-form diagnostic; conditional automatic equality does not
require them or restrict ordinary construction of Wrap[T].

Reject trait parameters, supertraits, impure trait requirements,
independently generic methods, associated types/constants, trait objects,
cross-type equality and implementation specialization with teaching diagnostics.
They are outside this increment, not silently admitted partial features.

For each `(TraitId, receiver head)` allow one authored implementation:
`Box[T]` and `List[T: Equatable]` are complete generic families; `Box[Int]`,
`Box[List[T]]` and repeated-parameter patterns are rejected in v1.
Receiver heads are existing primitive scalars, List, named records/unions and
opaque types. Explicit tuple/callable receivers are deferred too; supporting
them must not be inferred from their physical record/callable representation.
Bounds and parameter spellings do not distinguish implementation heads.
Resolve the head and arity first; its parameters must be distinct fresh,
unqualified binders. An imported type named T cannot be silently rebound.
A family replaces derivation for its entire head: failed authored bounds are
an error, never a reason to fall back to structural equality.
There is no per-method structural fallback; abstract methods are required,
and omitted defaulted methods use their actual trait default bodies.

This deliberately narrower receiver policy postpones overlap ranking.
Revisiting partial implementations requires its own coherent language decision.

## 2. Source examples and inference prerequisite

Examples are fragments unless module names are shown. The proposed fixture
prelude imports base types and Equatable; operation imports remain explicit.

**Source: final canonical declaration in the configured foundation.**

```blorp
trait Equatable:
    pure func equals(left: Self, right: Self) -> Bool

    -- Checked once with Self: Equatable in this declaration's scope.
    -- This calls the selected equals, including an authored override.
    pure func not_equals(left: Self, right: Self) -> Bool:
        match equals(left, right):
            True: False
            False: True
```

**Source: ordinary primitive implementation, in the fixture's int module.**

```blorp
import:
    _base: Int, Bool, Equatable

implements Equatable for Int:
    pure func equals(left: Int, right: Int) -> Bool:
        builtin("int.equals")
    -- not_equals uses the trait default; no second primitive hook.
```

**Source: declared bounds authorize a generic body.**

```blorp
import:
    int: equals

pure func same[A: Equatable](left: A, right: A) -> Bool:
    left.equals(right)

pure func forward[B: Equatable](left: B, right: B) -> Bool:
    same(left, right)

-- Rejected even if every current caller supplies Int.
pure func missing_bound[B](left: B, right: B) -> Bool:
    equals(left, right)
-- error: B is not known to implement Equatable
-- help: add B: Equatable to this function's type parameters
```

**Source: the first concrete fixture's normal entrypoint.**

```blorp
func main() -> Int:
    match equals(7, 7):
        True: 23
        False: 0
-- T1: exit 23, empty stdout/stderr. T3 also tests same(7, 7) here.
```

The checker first infers call type arguments from ordinary type equations.
It checks trait obligations once their receiver is known, including a rigid
parameter justified by its declared bound. Unresolved obligations wait within
the current expression's work, then report ambiguity. Available implementations
must never be searched to guess an unknown type.

The completed inference prerequisite accepts a typed sibling as nominal context
in either argument order, including nested calls. Its current rules live in
[README](README.md), its exact diagnostic oracles in
[test_records](test/unit/test_check/test_records.brp) and
[contextual tests](test/unit/test_check/test_contextual_inference.brp), and its
qualification and original cost baseline in the
[T0 report](../benchmarks/results/blorp2-nominal-context-2026-10-22.md).

**Source: supported expression-local context, independent of traits.**

```blorp
record Pair { first: Int, second: Int }

pure func make_pair() -> Pair:
    { first = 7, second = 9 }

pure func pick[T](left: T, right: T) -> T:
    left

pure func example() -> Int:
    -- The typed sibling determines Pair; fields do not select a record.
    pick(make_pair(), { first = 7, second = 9 }).first

-- Reversing the operands also works. Both evaluate once in written order.
```

**Source: method references need an expected callable contract.**

```blorp
-- The expected callable type determines Self = Pair.
compare: pure (Pair, Pair) -> Bool = equals

-- Rejected: neither this binding nor the method name determines Self.
ambiguous = equals

-- After ordinary List equality exists, this still has unknown element type.
-- equals([], []) must request type context, not choose an arbitrary impl.
```

Inference across later statements, generic-bound inference and unknown-result
block-lambda inference are separate projects. Already typed equality operands
do not depend on T0; avoid coupling concrete trait admission to a solver rewrite.

## 3. Phase ownership and identities

| Owner | Establishes and publishes | Must not do |
| --- | --- | --- |
| Parse/assembly | Located headers, abstract/default distinction, genuine declaration IDs and body ownership | Prove bounds or choose implementations |
| Namespace | Trait identity, method-family identity, imports/offers and visibility | Rank implementations by imports |
| Check | Method contracts, Self substitution, purity, completeness, ownership/coherence, bound entailment, derived eligibility and ordinary checked templates | Infer undeclared generic bounds |
| Specialize | Substitute semantic arguments, select an accepted static method body, request an ordinary function instance | Diagnose new user trait failures |
| Lower/Own/Verify/Emit | Existing concrete calls, branches, projections and ownership | Contain trait-specific variants/tables |

Current producer boundaries:
[check/check](src/check/check.brp):57–91 seals accepted declarations, signatures,
bodies and finite recursion;
[utils/syntax](src/utils/syntax.brp):642 always gives ParsedFunction a body;
[namespace](src/namespace/namespace.brp):58/176/184 stores functions as FunctionIds.
Abstract trait methods therefore need a signature/default sum, not a dummy
function body or invented FunctionId.

Current ParsedFunction.type_parameters is List[WrittenName]. Replace that
element with one located parsed parameter carrying its written bounds; reuse
the header parser, admitting bounds only for functions and impl receivers.
Resolve bound TraitIds
in Check, not Parse. Bind Self contextually in trait/impl scope, not as a global
reserved identifier. Preserve existing conflicts and public-contract visibility.

**Model sketch: minimum additional identities and facts.**

```blorp
-- IDs come from the ordinary declaration inventory.
opaque type TraitId = Int
opaque type ImplId = Int
private fixed record TraitMethodIdentity {
    owner: TraitId,
    position: Int
}
opaque type TraitMethodId = TraitMethodIdentity

fixed record TraitRequirement {
    receiver: TypeRef,
    required_trait: TraitId,
    span: Span
}

fixed record CheckedTraitMethod {
    id: TraitMethodId,
    signature: FunctionSignature,
    default_body: Option[FunctionId]
}

fixed record CheckedTrait {
    id: TraitId,
    self_parameter: TypeParameterId,
    methods: List[CheckedTraitMethod]
}

-- requirements joins the existing FunctionSignature, not a parallel signature.
-- TraitDeclaration and ImplementationDeclaration join TypeParameterOwner.
-- Record/union declaration bounds are outside this increment.
```

Keep check_builtin_types before Namespace for primitive/Bool/Option/Result
validation and the foundation-shape allowance. It publishes no unvalidated Eq.
Within the existing checker composition: resolve trait headers/Self and ordinary
declarations/signatures, validate method signatures, then designate optional
canonical Eq in the single accepted trait authority. Match only the foundation
module's declared Eq name and validate pure Self/Self -> designated Bool once.
equals must be its sole abstract requirement; any additional admitted method
must have an ordinary default. Reject an extra abstract requirement as a
malformed canonical trait, with a precise header diagnostic, before derivation.
Next validate impl contracts/coherence, check default/impl/ordinary bodies and
on-use derivation, run the extended finite-instantiation check, then seal.
Defaults are checked once under rigid Self, even if every impl overrides them.
All generic applications, including function references, must discharge the
selected function/receiver requirements; no check waits for code generation.

Authored implementation methods and default bodies receive genuine FunctionIds
once, in the ordinary inventory. Abstract methods do not. Normalize each
authored body's Self/header parameters into its own function-parameter domain
once; retain the argument mapping from the implementation/method contract.
Current [parameter_substitution](src/specialize/specialize.brp):936 validates a
single owner and consecutive positions; mixing header/function owners is invalid.

**Model sketch: sealed call fact.**

```blorp
private fixed record MethodCallContents {
    method: TraitMethodId,
    receiver: TypeRef
}
opaque type AcceptedMethodCall = MethodCallContents

-- Existing CallTarget gains TraitMethod(AcceptedMethodCall).
-- Only checking constructs it after proving the requirement.
-- There are no trait/method argument lists: v1 has neither kind of parameter.
-- Existing CallableChoice gains the same method choice for callback/value paths.
-- CheckedCall.operands remains the single source-ordered operand list.
```

Keep one immutable accepted trait/implementation declaration authority in
CheckedFunctions. It stores each accepted family and complete method mapping
once; rows refer to existing authored/default bodies or the derived body below.
Construction prevents missing/duplicate methods. Do not retain a second
per-call proof tree, signature copy, dispatch registry or callable graph.

**Model sketch: one implementation row and complete method mapping.**

```blorp
fixed record CheckedMethodBody {
    method: TraitMethodId,
    body: BodyOwner,
    arguments: List[TypeRef] -- Map header parameters into the body's own domain.
}
fixed union ImplementationOrigin:
    AuthoredImplementation(ImplId)
    StructuralEquality(AggregateId, CheckedEqualityBody)
fixed record CheckedImplementation {
    required_trait: TraitId,
    receiver: TypeRef,
    parameters: List[TypeParameterId],
    requirements: List[TraitRequirement],
    origin: ImplementationOrigin,
    methods: List[CheckedMethodBody]
}
-- CheckedEqualityBody holds the ordinary checked signature/bindings/statements/body,
-- without a fabricated declaration FunctionId. StructuralEquality owns it once.
-- The complete methods list maps equals to DerivedEqualityBody(aggregate);
-- not_equals maps to the genuine default FunctionId with Self = receiver.
-- Derived Wrap[T] has T: Equatable as an internal template assumption.
-- Derived Phantom[T] has no such requirement when T occurs in no actual field.
-- These inferred template requirements never add bounds to a user's function.
```

### Imports and implementation ownership

Add TraitId to trait-name lookup and TraitMethodId to value-family lookup.
A trait is not an ordinary value type. An impl module's own public method
offers its method family; merely importing a family does not reexport it.
Multiple routes to the same MethodId coalesce. Distinct families, or a free
function and family sharing one spelling, retain explicit conflict/qualification
rules. Keep module aliases; do not add arbitrary overload sets.

Keep one namespace build. Within its existing dependency-order walk, enter a
module's type/trait headers and ordinary declarations, resolve its
imports/aliases/prelude against frozen dependencies, then resolve own impl
trait references in that same scope. Publish every method family of the trait,
including omitted defaults, and freeze one ModuleScope. Impl/default function
rows are tagged as such and never also offered as free functions. Check later
validates members, receiver types and ownership; this introduces no dependency
from Namespace to Check. Coalescing an imported and declared family must retain
the declared offer authority.

For Type methods_only, the provider must have an accepted own implementation
for that receiver head. Expose its family across Self after admission; merely
importing Int into a provider must not expose an unrelated Foo implementation.

**Source: importing an implementation's method does not restrict Self to Int.**

```blorp
import:
    int: equals

fixed union Mode:
    Read
    Write

pure func same_mode(left: Mode, right: Mode) -> Bool:
    equals(left, right) -- Canonical family, derived Mode implementation.

-- int-as-alias qualified calls and methods_only exposure follow the same rule.
-- An old free equals(Int, Int) remains Int-only until its declaration migrates.
```

Authored impls belong in the trait's or receiver's declaring module.
One explicit standard-library allowance is necessary: when BOTH declarations
belong to the designated foundation module, an implementation may live in a
sealed `LibraryModule`. This accommodates Int/List operations outside _base.
Use declaration module IDs and `ParsedModuleRow.role`, never filenames,
directory prefixes or importing-module ownership. Application roots remain
`UserModule` even beneath the supplied library directory. The allowance does
not permit an application to implement a foreign foundation type/trait.

Freeze all authored families before derived eligibility. Selection is global
within the loaded program; imports control method visibility, not semantics.
Defaults use the trait definition's lexical scope, authored methods their
implementation scope. Coherence does not depend on declaration/import order.

### Semantic identity before representation erasure

Function instance and known-callable keys retain fully substituted semantic
checked types, including opaque identity and callable purity. No rigid parameter
may remain in these arguments. Repeated requests with the same semantic types
and callable choices reuse the existing function-request graph; no parallel
semantic/physical public key or recursive witness graph is introduced.

Record, union and callable-capture layout keys retain representation sharing
within their existing declaration/site identities. Physical substitutions are
projected at layout boundaries; they never reconstruct behavior identity.
Same-storage opaque substitutions therefore may share storage while keeping
distinct function bodies and callable choices. The completed T2 report above
records collision/reuse coverage, instance/C growth and matched compiler costs.

## 4. Automatic equality as ordinary checked code

Requirements come from actual fields and variant payloads, with declared
function/receiver assumptions respected. They do not come from every formal
type parameter or silently constrain ordinary record construction.

**Source: conditional derivation and authored replacement.**

```blorp
record Wrap[T] { value: T }      -- Requires T: Equatable when equality is used.
record Phantom[T] { tag: Int }  -- Does not require T: Equatable.

record Handler {
    key: Int,
    callback: pure (Int) -> Int
}
-- Handler is legal. Its automatic equality is unavailable.

implements Equatable for Handler:
    pure func equals(left: Handler, right: Handler) -> Bool:
        left.key.equals(right.key)
-- This whole authored implementation intentionally ignores callback.
-- An enclosing derived record must call it, not inspect Handler's fields.

record Envelope { handler: Handler }

-- A generic authored family replaces auto equality for every Wrap.
implements Equatable for Wrap[T: Equatable]:
    pure func equals(left: Wrap[T], right: Wrap[T]) -> Bool:
        left.value.equals(right.value)
-- A different bound on another Wrap implementation does not create another slot.
```

**Source-equivalent generated record body; no handwritten helper is required.**

```blorp
-- For record Point { x: Int, y: Int }:
match left.x.equals(right.x):
    False: False
    True: left.y.equals(right.y)
-- Declaration order and short circuit are semantic requirements.
-- Eager and(equals(x...), equals(y...)) would compare y unnecessarily.
-- Never use memcmp, pointer identity or a same-object early True shortcut:
-- padding, authored equality and Float NaN make those unsound.
```

**Source-equivalent generated union body.**

```blorp
-- For fixed union Reply: Empty; Value(Int)
match left:
    Empty:
        match right:
            Empty: True
            Value(_): False
    Value(left_value):
        match right:
            Empty: False
            Value(right_value): left_value.equals(right_value)
-- Different tags return False without inspecting payloads.
-- Compare equal-tag payloads in declaration order; empty payloads return True.
-- Use genuine variant/field identities, including logical erased-Void positions.
```

Generate ordinary CheckedExpr/CheckedBody templates, not parsed source strings.
Check their projections, result/purity and nested method obligations before
publication. Reuse aggregate declaration parameters and the current instance
request/expansion graph.

**Model sketch: derived body identity without forged declarations.**

```blorp
fixed union AggregateId:
    RecordAggregate(RecordId)
    UnionAggregate(UnionId)

-- Existing BodyOwner becomes:
fixed union BodyOwner:
    DeclaredBody(FunctionId)
    LambdaBody(LambdaId)
    DerivedEqualityBody(AggregateId)

-- Store the ordinary checked template once in its structural implementation row.
-- SelectedBody.root: FunctionId becomes parameter_owner: TypeParameterOwner.
-- Declared/lambda bodies use FunctionDeclaration(their genuine root);
-- generated bodies use RecordDeclaration/UnionDeclaration of the aggregate.
-- No GeneratedFunctionId table and no invented main/root/function slot.
```

### Recursive eligibility and collections

For mutually recursive aggregates, compute component requirements to a finite
fixed point in checker-local work. An active backedge is provisional, not a
globally accepted implementation. Publish the whole supported dependency group
only after every outgoing dependency succeeds. Discard failed provisional facts.

**Source: positive and poisoned recursive cases.**

```blorp
fixed union Tree:
    Leaf(Int)
    Branch(List[Tree])
-- Tree -> written List equality -> Tree can close once every other
-- obligation succeeds. Actual values are finite and acyclic.

record BadNode {
    children: List[BadNode],
    callback: pure (Int) -> Int
}
-- BadNode -> List[BadNode] -> BadNode does NOT prove the callback equatable.
-- Declaration alone succeeds; equality use rejects and names callback.
-- Reverse field/declaration/use order in tests to catch optimistic caching.
```

This is the structural equality rule, not general acceptance of circular trait
proofs. Preserve existing finite type/generic-instantiation restrictions.
Extend [recursion](src/check/recursion.brp)'s existing analysis to generated
bodies, trait-call edges and method-value creation; never discover an unbounded
specialization family as a new user error in Specialize.

**Source: reject an expanding trait-selected call before Specialize.**

```blorp
trait Visit:
    pure func visit(value: Self) -> Int

implements Visit for List[T: Visit]:
    pure func visit(value: List[T]) -> Int:
        visit([value]) -- The next method-body T is List[T], then List[List[T]].
-- The trait requirements hold, but the reachable instance family grows forever.
-- Also test creation/invocation of a typed visit reference at List[List[T]].
```

Project symbolic trait edges through the accepted receiver-to-body argument
mapping into the existing finite-instantiation analysis. Merely adding a
TraitMethod match arm to its current FunctionId-only call observer is insufficient.

List equality is an ordinary bounded implementation, not compiler derivation
or a generic runtime hook. Keep the algorithm linear without zipped/copied Lists.

**Source: T4 isolated fixture-library method; production migration waits for T5.**

```blorp
implements Equatable for List[Element: Equatable]:
    pure func equals(left: List[Element], right: List[Element]) -> Bool:
        count = length(left)
        match IntOps.equals(count, length(right)):
            False: False
            True:
                var index = 0
                var matched = True
                while IntOps.less_than(index, count):
                    match get(left, index):
                        None:
                            matched = False
                            break
                        Some(left_item):
                            match get(right, index):
                                None:
                                    matched = False
                                    break
                                Some(right_item):
                                    match equals(left_item, right_item):
                                        False:
                                            matched = False
                                            break
                                        True:
                                            index = IntOps.add(index, 1)
                matched
-- Imports: _base Int/List/Equatable/Bool(True,False)/Option(Some,None),
-- and int as IntOps; length/get are local ordinary functions.
-- The nested equals names the same family with Self = Element.
-- Option cases are handled without panics; inputs are evaluated once.
```

Option/Result/Bool are ordinary unions and use the same derivation rule.
String/Int/Float keep their existing primitive semantics. Float NaN remains
unequal to itself; this work adds no stronger reflexivity guarantee.

## 5. Useful precedents, and deliberate differences

These are specific lessons, not instructions to import another compiler's
framework. References were checked on 2026-10-22.

- **Rust: assumptions and implementation selection.** A generic bound supplies
  an assumption used to prove nested requirements; concrete method selection
  follows substitution. Reuse that distinction, with a sealed accepted call in
  Blorp. Rust's solver handles many features absent here; its candidate search,
  canonical responses and broader infrastructure are not this plan.
  [Current solver concepts](https://rustc-dev-guide.rust-lang.org/solve/trait-solving.html);
  [older selection/typecheck explanation](https://rustc-dev-guide.rust-lang.org/traits/resolution.html).
- **Rust: one reachable monomorphization graph.** Concrete generic instances
  are collected for code generation. Blorp already has that graph; methods and
  generated equality must join it. This does not make additional instances free.
  [Monomorphization](https://rustc-dev-guide.rust-lang.org/backend/monomorph.html).
- **Rust: coherent authored implementations.** Required members must exist,
  defaults may be overridden, and overlapping impls are rejected. Blorp's first
  head-family rule is narrower. Rust's ownership unit is a crate; Blorp uses
  module ownership plus the explicit foundation-library allowance above.
  [Trait implementations](https://doc.rust-lang.org/reference/items/implementations.html#trait-implementations).
- **Swift: memberwise synthesis.** Stored properties and enum payloads determine
  eligibility; user implementations replace synthesized equality. Swift's
  synthesis generally requires explicit conformance. Blorp deliberately needs
  no opt-in declaration and derives only on demand, so its recursive eligibility
  cannot merely assume that another type opted in.
  [SE-0185, implemented design](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0185-synthesize-equatable-hashable.md).
- **Haskell: derived requirements and recursion.** The report defines derived
  constraints from constituent types and describes fixed-point calculation for
  mutual recursion; comparisons proceed left to right. This supports the
  phantom-parameter and complete-dependency rules above. Blorp's generation is
  demand-driven, needs no deriving clause and emits ordinary specialized calls.
  [Derived instances, sections 10–10.1](https://www.haskell.org/onlinereport/derived.html).
- **Rust: PartialEq is the relevant equality comparison.** Its structure/enum
  behavior, required equality/default inequality and Float NaN distinction are
  useful references. Blorp's Equatable is homogeneous; do not add Rust's Rhs
  parameter or conflate it with Rust's stronger Eq marker. No compiler memory
  or ownership optimization may assume authored equality laws.
  [PartialEq](https://doc.rust-lang.org/std/cmp/trait.PartialEq.html).

## 6. Milestones and runnable acceptance

No parse-only scaffolding milestone lands by itself. Each milestone includes
its complete producer/consumer path, exact diagnostics, reference/EBNF updates,
two independent reviews and one coherent commit. T0 and T2 are complete;
T3 must land before T4. The table below contains only open milestones.

Start each milestone with its red oracle. T1 begins with the
exit-23 fixture and contract rejections. T3 adds the missing-bound rejection
before admission; T4 starts with a derived
container whose nested authored equality intentionally differs from fieldwise
comparison. Do not remove old negative coverage merely to turn a suite green.

| Milestone | Deliverable and changed boundary | Completion oracle |
| --- | --- | --- |
| T1: concrete explicit traits | Parse, inventory, namespace, Check; abstract methods and concrete impls; default bodies deferred explicitly | Fixture Int and custom type direct/UFCS/qualified calls; missing/extra/duplicate/impure members and orphan impls reject in Check |
| T3: bounds/defaults/callables | Function/receiver bounds; default bodies; contextual method references; accepted symbolic target | Generic forwarding works, missing bounds reject without callers; default dispatch honors override; callbacks keep evaluation order/purity |
| T4: structural equality | Ordinary derived record/union templates, dependency closure, ordinary List prerequisite in isolated fixture library | Recursive/custom/phantom/invalid-field cases below pass; no trait-specific concrete/lower products |
| T5: production library rollout | Qualify/publish/pin capable seed, then migrate target library APIs | Clean bootstrap/fixpoint and all component/native/platform gates pass without legacy building Blorp 2 |

T1 accepts a canonical equals-only declaration in its isolated fixture base;
the designation validates that required method's exact pure Self/Self -> Bool
contract. T3 adds the ordinary not_equals default. No magic semantics are
attached to any other method spelling.

### Acceptance matrix

| Boundary | Required positive and negative cases |
| --- | --- |
| Inference | Typed sibling/literal in both orders; nested generic result; two same-shaped nominal records never guessed; no-context literal remains ambiguous; missing names and incompatible arguments retain specified first-error spans; once-only source-order effects |
| Trait identity | Canonical versus unrelated same-spelled trait; malformed canonical header with extra abstract method rejects; Self scoped by identity; duplicate methods; trait used as value type rejects; unsupported syntax has exact help |
| Contracts | Missing/extra/duplicate members; Self substitution; changed parameter names accepted; wrong arity/result/parameter/purity rejects; bodies checked even when unreachable |
| Coherence/imports | Own trait/type and foundation-library allowance; user orphan rejection; bound-varying duplicate heads reject; same family import routes coalesce; different families/free-function clashes; qualified/methods_only/no-reexport behavior |
| Bounds | Concrete and generic calls; nested requirements and forwarding; distinct rigid A/B never unified; no-bound generic fails even with only Int callers; failing authored-family bounds never fall back |
| Callable paths | Expected callable chooses Self; bare equals ambiguous; named callback, returned/stored reference and generic forwarding preserve method choice; pure/impure permissions and interleaved effects remain ordinary |
| Derived data | Empty/nonempty/fixed/managed/generic records/unions; all union cases count for eligibility; logical Void fields; phantom callable argument succeeds but actual callable field fails; nested custom semantics; Float NaN |
| Recursion | Finite Tree/List and mutual aggregate positives; recursive callable poison in reordered cases; valid/invalid substitutions cannot poison one another; existing expanding-instantiation rejections |
| Specialize/ownership | Opaque versus underlying and two opaque types select different methods; repeated key reuse; unreachable methods absent; derived calls join existing graph; ordinary borrow/acquire/drop behavior and no trait below Specialize |
| Diagnostics | Exact typed error, message/help/span and originating field/impl note; use-site error with real bad-member path; rejected CLI compilation preserves output sentinel and writes no new C |

Short-circuit verification belongs in checked/concrete branch unit tests;
pure equality cannot use an impure trace as an oracle. Native custom-equality
values and NaN provide independent behavior checks. Mutate one bound admission
and one nested custom dispatch temporarily: the corresponding exact checker
and native tests must fail. Restore and hash inputs before final gates.

### Feedback loop

Run from the repository root. Build/status/toolchain provenance follows
[WORKER_CHECKLIST](../docs/WORKER_CHECKLIST.md). Commands below are prospective;
this document is not a record of executed gates.

```sh
scripts/compiler-build-status
# If not FRESH, rebuild the existing host with make before direct host tests.

# Recheck contextual inference when extending trait call checking.
bin/blorp test --std-dir standard_library/src --suite --timeout 180 \
  blorp_2/test/unit/test_check/test_records.brp

# T1–T4 create these ordinary suites, then run only the relevant one first.
bin/blorp test --std-dir standard_library/src --suite --timeout 180 \
  blorp_2/test/unit/test_parse/test_traits.brp \
  blorp_2/test/unit/test_check/test_traits.brp \
  blorp_2/test/unit/test_specialize/test_traits.brp

# This host suite parses compiler source with the B2 parser before a pinned build.
bin/blorp test --std-dir standard_library/src --suite --timeout 180 \
  blorp_2/test/unit/test_parse/test_source_tree.brp

# Early iteration only: build once, run the focused native owner under this A.
make -C blorp_2 test-compiler
# Do not pass e2e input fixtures to the legacy compiler.

# Final qualification: preserve any previous fixed-output proof artifacts first.
# These explicit inherited policies retain allocation FAIL/debt markers and
# label broad instruction checks unmeasured; they are not feature cost evidence.
BLORP_2_RESOURCE_POLICY=record-allocation-debt \
  BLORP_2_INSTRUCTION_CHECK=disabled scripts/blorp2-fixpoint --prove

# Use the actual B already generated by the proof; do not regenerate it here.
make -C blorp_2 test-components \
  BLORP2_COMPILER="$PWD/blorp_2/build/fixpoint/stage_b"
```

Use [module_input](test/unit/module_input.brp)'s explicit TestFoundation for unit
inputs. New e2e suites compile their real main through the candidate's existing
`--library-root` route, using [test_strings](test/e2e/test_strings.brp)'s isolated
invocation precedent and normal native harness. Keep one normal test aggregator,
unmodified emitted C and no generated-internal-symbol calls. Existing
test-components includes hosted suites AND the maintained target selection;
hosted-only success is incomplete.

Register each new e2e suite in the maintained aggregator. Keep isolated
trait-library inputs outside the default-library fixture scan: --prove's
automatic fixture comparison supplies only the ordinary library root.
For each accepted/rejected trait fixture, also compile the identical preserved
source/library under actual A and B with explicit --library-root, compare
status/stdout/stderr and accepted C bytes, then run the normal native oracle.
This is an additional use of existing entrypoints, not a second test main.
The regular B e2e run must execute these cases too.

The public verify_native_output helper links diagnostics=0 with sanitizers;
it does not prove balanced strict accounting. Link the SAME emitted C separately
with diagnostics=1 and run its real main with BLORP_LEAK_CHECK=strict, requiring
nonnegative balanced counts, zero leaked bytes and no other diagnostic. The
Int-only first fixture may legitimately allocate zero; also qualify an
intentionally allocating aggregate/List fixture with positive balanced counts. Reuse
existing command/report primitives or a narrow shared helper, not emitted-code
rewriting. Give every compiled gate a finite administrative deadline.

## 7. Efficiency, bootstrap safety and handback

### Prospective ceilings and measurement

For the full traits feature, retain the +5% cumulative ceiling for matched
self-compile allocations and normal retired instructions against the one frozen
pre-T0 compiler workload, not compounded milestone allowances. Completed T0 used
a +1% ceiling and T2 a +2% investigation trigger against that same reference;
their reports retain the actual results.

Use a production-code review envelope of +2,000 net handwritten lines for
T0–T4, investigate the forecast at +1,500, and report gross ADD/DEL/net per
milestone with tests/library/docs separately. This is a complexity guard,
not a target; never compress formatting or delete coverage to meet it.
Required test growth is reviewed for value rather than forced into that cap.

Freeze baseline sources/library, CWD/output pathname, environment, seed,
normal/diagnostic binaries and C toolchain. Use one strict original/candidate
pair and one predetermined six-normal schedule P1 C1 C2 P2 P3 C3 at -O0.
P always means the preserved original pre-T0 compiler, C the current candidate.
Strict runs must have positive balanced allocations/releases and zero leaks.
Compare minimum-of-three actual normal retired instructions. Retain every
sample, hash and failure; no favorable reruns. Also record current-source
self-compile separately from the frozen-input comparison.

Retain the original baseline compiler roles for every comparison; compare
original and current candidate quietly on that same input, never compound
parent ratios. The completed milestone limits and final +5% ceiling share this
one reference. Immediate-parent source diffs do not change the cost baseline.
Before each call ensure the one physical output path is absent; archive its
result afterward. Freeze all of these details before the first sample.
Semantic instance splitting can change old-input C; require old-input
native/diagnostic parity and same-version A/B fixpoint. Freeze the expected
output policy before measuring, not after a miss.

Build paired binaries from the same actual compiler C, with
`BLORP_MEMORY_DIAGNOSTICS=0/1`. See [Makefile](Makefile)'s separate link targets.
Use the existing native harness's platform counters or `/usr/bin/time -l` on
macOS; a missing counter is unmeasured, not zero. Do not apply the legacy
self_compile_measure CLI to Blorp 2 or assume its historical lock serializes
anything. Root schedules the CPU lane.

For T3/T4 also freeze trait fixtures covering generic width, repeated same
obligations, deep finite nesting and mutually recursive equality. Record
reachable function/aggregate counts, output C bytes, allocations and
instructions; reject repeated per-use rebuilding or superlinear collection
growth. Set fixture absolute limits from a retained first baseline before
optimization, with one named governing record. Existing broad resource debt
remains visible; cost-disabled CI is not performance evidence.

Modest evidence-backed budget amendments belong with the milestone and its
reviews; do not create permission loops for trivial adjustments. Significant
growth, a second semantic authority or new downstream trait machinery requires
rescoping. No efficiency improvement is claimed by this proposal.

### Bootstrap and library boundary

The current [bootstrap manifest](bootstrap.env) pins a seed that cannot parse
traits. Keep compiler implementation source and the default target library
seed-compatible through T4. Qualify new source-language fixtures with an
explicit trait-capable test foundation/library; do not add an alternate builder.

Canonical Eq is optional while the supplied old foundation has no trait:
`None` means no canonical auto equality, not fallback recognition by spelling.
When present, designate and validate genuine Eq/equals IDs once through the
existing foundation authority. _base may contain specifically owned trait
default bodies after T3, while unrelated free functions/imports remain rejected.
A same-spelled trait outside the designated base remains ordinary.

T5 uses the maintained [release procedure](../docs/RELEASES.md) and
[bootstrap launcher](../scripts/blorp2-compiler-bootstrap).
Publish/qualify the capable seed and pin it before any default library syntax
migration. Then move equals/not_equals into written implementations atomically
with all affected target-library consumers/tests/reference docs. Preserve
builtin primitive contracts. Compiler-source migration is a later bounded
cleanup, not permission to rewrite every comparison now.

Update Blorp 2 README/grammar at each feature milestone; update shared
GUIDE/GRAMMAR where their contracts change. In particular remove stale claims
about tuple-only derivation, unavailable payload-union equality, all generic
arguments requiring Eq, per-implementation default checking and specialized
Wrap[Int] replacement. Do not change legacy compiler source or invent
compatibility syntax. Back out a bad milestone by reverting its coherent code,
tests/docs and any dependent later milestones; never patch emitted C.

### Worker handback and stop rules

Return the branch/base, changed producer/consumer facts, test counts and exact
diagnostic examples, raw evidence paths/hashes, matched costs and separate line
counts, two independent verdicts, and remaining limitations. Root integrates
and verifies publication. Group related plan/reference edits with code; avoid
planning-only main pushes.

Stop and report a reduced example when inference needs global body inference,
ownership needs trait-specific handling, generic identity requires a second
proof graph, recursive requirements cannot close finitely, or the scoped
surface must grow. State the tried approach, evidence and smallest alternatives.
Do not silently downgrade a supported call form, infer bounds from callers,
accept provisional recursive success, or route around a bootstrap/compiler bug.
