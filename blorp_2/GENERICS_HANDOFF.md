# Check generic declarations once, specialize before lowering

## Problem

The next language increment is ordinary type parameters on functions, followed
by generic fixed unions. The user wants small executable examples and complete,
immutable checked facts as the basis for later phases. This is compiler work,
not a request to wrap the host compiler or copy its implementation.

First add this fixture, without the explanatory comments or blank lines:

```blorp
pure func identity[T](value: T) -> T:
    value
func main() -> Int:
    integer = identity(7)
    text = integer.to_string().identity()
    identity(text).length()
```

Run the pilot directly after `make -C blorp_2 test-compiler`:

```sh
blorp_2/build/compiler blorp_2/src/prelude_temp.brp \
  blorp_2/test/e2e/fixtures/generic_identity.brp \
  blorp_2/build/generic_identity.c
```

Currently `[` is unsupported, so compilation fails in lexing. Capture the
exact first diagnostic in the failing test before implementation. Afterward,
the unmodified emitted C must build and its real `main` must return 1 with
empty stdout and stderr. The same generic declaration is exercised with both
unmanaged `Int` and managed `String`.

## Background

Read parent [AGENTS.md](../AGENTS.md), then [AGENTS.md](AGENTS.md),
[README.md](README.md), [grammar.ebnf](grammar.ebnf), and the relevant
contracts in [MEMORY_PLAN.md](MEMORY_PLAN.md). Follow
[HANDOFF_SPEC.md](../docs/HANDOFF_SPEC.md). Act as compiler-expert, including
parser-specialist, ergonomics-expert, and data-engineer for the initial design;
the coordinator arranges independent review. Read
[compiler-expert.md](../.claude/agents/compiler-expert.md).

Existing compiler source may use the agreed eventual subset, including generics,
but input-program scope is much smaller: zero/one runtime argument, nominal
fixed unions with zero/one Int payload, bindings and local mutation, acyclic
calls, direct calls and UFCS, exhaustive terminal matches, explicit purity,
and a tiny explicitly supplied input prelude. No traits or operator sugar.
Tests use Blorp `TestSuite`. There is no persistent compiler cache.

Starting revision is `bb0b28d1edbd3ff5d3f010b25eec24cd815a9a4c` on `blorp-2`.
A separate agent completed fresh String results in terminal match arms before
this handoff was released for implementation. Its shared `ReturnTransfer`,
`OwnedMatch` and `OwnedArm` contracts replace the earlier unmanaged-only path.
Managed prefixes and parameters remain rejected. Consume the exact uncommitted
source snapshot and [tail-String record](../benchmarks/results/blorp_2_tail_strings_2026-10-09.md),
not HEAD alone. Independent review approved the slice; strict sanitized units
passed 307 callbacks and full pilot validation passed 443 including wrappers.
Current source excerpts below come from the starting revision; frontend sites
are unchanged by that preceding ownership slice.

The existing language's semantics are in
[GUIDE.md, Generics](../docs/GUIDE.md#generics): explicit declarations,
capital ASCII parameter names, opaque type parameters inside a body. Use its
square-bracket syntax. The full compiler is precedent, not code to transplant.
The pilot still cannot compile itself; owned-input costs are proxies only.

## Proposed solution

Implement two independently green slices. First, one ordinary type parameter
on functions, inferred from the sole runtime argument, including direct calls,
UFCS, and generic forwarding. Then add one type parameter on fixed unions,
type applications in annotations, and Int-payload concrete instances. Report
the first slice for review before broad implementation of the second. Both
are authorized; do not add managed union children in the second slice.

Check every declaration body once with rigid type parameters, including unused
declarations. Infer call substitutions locally, validate arity/purity/types
there, and publish resolved typed instantiation requests. Add an explicit pure
specialization boundary between checking and value lowering. It builds concrete
functions and union instances from accepted facts, without name resolution,
rechecking bodies, or guessing meaning from spelling. Ownership and emission
consume concrete types and call targets only.

For this increment, generic call inference uses the synthesized argument type
only; expected return types do not choose a substitution. Thus
`identity(First)` and `identity(Number(7))` reject even inside a union-returning
function. A nongeneric receiving parameter still contextualizes constructors,
as before. Offer an already-typed union value or concrete helper as the
diagnostic's workaround; typed local annotation syntax is not yet supported.

For this pilot increment, reject a type-parameter declaration that collides
with a prelude builtin or declared union type name, including its own union's
name. Diagnose the parameter's span and suggest a distinct name such as `T`.
Parameter spellings may be reused in different declarations, where they have
distinct identities. This is an explicit MVP restriction, not builtin-first
lookup that silently ignores a declared parameter.

Before implementation, send the coordinator a bounded identity/authority map,
product shapes, inference rules, unsupported cases, file changes, and shortest
test loop. Resolve these responsibilities explicitly:

| Fact | Identity and owner | Producer and lifetime |
| --- | --- | --- |
| Declaration | Function/union declaration ID in checked program | Checker; one compilation |
| Type parameter | Declaring authority plus parameter position | Declaration checking; generic body lifetime |
| Concrete union type | Union instance ID, keyed by declaration and concrete argument | Specialization; concrete program lifetime |
| Concrete function | Function instance ID, keyed by declaration and concrete argument | Specialization; through emission |
| Variant | Concrete owning union instance plus variant position | Checked specialization translation |
| Local binding/value/owner | Existing distinct function-local domains | Existing checking/lowering/ownership boundaries |

Equal integer ordinals across domains are not translations. The existing
`FunctionId` is a declaration ID; do not silently reuse it for specialized
functions. A type parameter owner is explicitly a function-declaration or
union-declaration variant: function 0's `T` differs from union 0's `T`.
One local compilation-owned instance authority is necessary to
issue unique instances, not a persistent cache. Start with simple local
builders and scans. Freeze once. No extra lookup index without evidence.

Publish a sealed concrete product that `lower` requires. Concrete type data
must exclude unresolved type parameters. Use checked translations for calls,
signatures, bindings, expression facts, constructors and matches. Do not
publish competing signature copies or expand boundaries into optional
authorities. Choose a simple module dependency direction; moving a bounded
shared type definition is preferable to circular imports or bypassing seals.

Preserve checking of all bodies and existing acyclic-call rejection. State
the instance root policy: preserve emission of ordinary nongeneric functions
unless a separately justified change is needed, then expand generic requests
from emitted concrete bodies. Do not sneak in a dead-code-elimination project.
No polymorphic recursion, arbitrary specialization cap, or runtime generic ABI.

## Code

Current declaration syntax (`src/syntax.brp:106`):

```blorp
fixed record FunctionHeader {
    purity: Purity,
    function_name: WrittenName,
    parameters: ParameterList,
    return_type: WrittenName
}
```

Add an explicit optional type-parameter declaration and parsed type syntax
where needed; parser output retains written names/spans. The checker resolves
them once to owned identities. `ParsedFunction` at line 191 and `ParsedUnion`
at line 212 need the corresponding source facts. Do not interpret uppercase
names downstream as proof they denote a type parameter.

Current checked types (`src/check.brp:53`) and published boundary (line 207):

```blorp
fixed union TypeRef:
    IntType
    StringType
    UnionType(UnionId)
fixed record CheckedFunctions {
    unions: List[CheckedUnion],
    functions: List[CheckedFunction],
    entrypoint: FunctionId
}
opaque type CheckedProgram = CheckedFunctions
```

The generic checked representation must admit rigid parameters and symbolic
union applications. The concrete representation must not. Illustrative
boundary shapes, to refine proportionately rather than copy mechanically:

```blorp
fixed union CheckedType:
    CheckedInt
    CheckedString
    CheckedParameter(TypeParameterId)
    CheckedUnionApplication(UnionDeclarationId, CheckedTypeArgument)
fixed union ConcreteType:
    ConcreteInt
    ConcreteString
    ConcreteUnion(UnionInstanceId)
opaque type SpecializedProgram = SpecializedContents
pure func specialize(program: CheckedProgram) -> Result[SpecializedProgram, Diagnostic]:
    ...
pure func lower(program: SpecializedProgram) -> Result[LoweredProgram, Diagnostic]:
    ...
```

`CheckedTypeArgument` must distinguish nongeneric from one generic argument,
not use a magic empty type. Avoid inventing recursive type machinery before
the union example needs it. The sealed producer owns completeness checks.
Current `main.brp:35` has `check → lower → own → verify → emit`; afterward:

```blorp
checked ?= check(parsed)
specialized ?= specialize(checked)
lowered ?= lower(specialized)
owned ?= own(lowered)
verified ?= verify(owned)
emit(verified)
```

This makes memory analysis independent of generic inference. For the first
fixture, specialize `identity` twice. The Int instance returns its argument
without RC. The String instance accepts a borrowed String and establishes an
owned return before the caller releases its earlier obligation. Repeated
requests reuse the same instance; distinct declarations remain distinct.

Generic forwarding must work, without checking the body again for each type:

```blorp
pure func identity[T](value: T) -> T:
    value
pure func forward[Element](value: Element) -> Element:
    identity(value)
func main() -> Int:
    forward(42)
```

Conversely, reject this body even if called only with Int, or never called:

```blorp
pure func bad[T](value: T) -> T:
    42
```

`Int` is not arbitrary `T`. Similarly `value.length()` and `to_string(value)`
cannot assume an unconstrained `T` is String or Int. Return-context inference
must not erase that distinction. Generic forwarding records the caller's rigid
parameter as the callee's symbolic substitution; equal spelling is irrelevant.
For uninferable calls, give precise span,
message and actionable help rather than choosing an arbitrary type.

Second working example:

```blorp
fixed union Box[T]:
    Box(T)
pure func box[T](value: T) -> Box[T]:
    Box(value)
pure func unbox[T](value: Box[T]) -> T:
    match value:
        Box(payload):
            payload
func main() -> Int:
    unbox(box(7))
```

It exits 7. Constructor inference uses the receiving checked type; pattern
resolution uses the scrutinee's union identity. Substitution carries variant
membership and payload type into the concrete instance. Do not rediscover
them from constructor names during lowering/emission. `Box[String]` needs
managed-child destruction, which remains unsupported with a tested diagnostic.
Even identical physical shapes do not make distinct nominal instances equal.
The first union slice admits one nonapplied argument in written annotations:
`Int`, `String`, a declared parameter or an ordinary nongeneric union. Written
nested applications such as `Box[Box[Int]]` remain explicitly unsupported.
Generic functions may still receive already-typed nominal union values.
Union payload annotations are `Int` or the union's declared parameter;
specialization rejects a concrete payload other than Int with source provenance.

Written arguments remain atomic, but semantic substitution must preserve a
complete checked type: use an applied-union variant containing its declaration
ID and checked argument type. For example, `box(box(7))` produces a semantic
nested application even without nested written syntax. Reject its outer non-Int
payload at specialization; do not lose the inner nominal identity. Equality and
substitution include the entire argument. Concrete keys use declaration plus
fully concrete argument, including nominal union instance IDs.

Preserve annotation locations by replacing checked signature type fields with
`TypeUse` records, rather than copying the signature into another authority.
Keep initiating concrete call-request provenance outside instance-key equality;
ordinary roots explicitly have no call site. Carry that initiating location
through forwarding. A written unsupported application uses its annotation span;
a symbolic application becoming unsupported uses its concrete request span.
Retain the payload annotation span in the checked union. A narrow closed
`DiagnosticNote = NoDiagnosticNote | UnionPayloadDeclaration(Span)` lets the
renderer show the payload declaration alongside the primary error, without a
general diagnostic framework. Test both locations and help for written,
forwarded symbolic and semantic nested applications. Phantom String applications
with no managed payload remain valid.

Recursive checked types may change physical storage in the host compiler.
Before broad union implementation, migrate the minimal semantic carrier and
probe three samples per unchanged workload against the original post-tail
baseline on allocations, instructions and C identity. The cumulative 25%
investigation threshold still applies; do not advance the baseline between
slices or add a type registry to avoid an unmeasured cost.

## Scope and non-goals

Own pilot syntax/lex/parse/check, a small specialization module, necessary
downstream type/ID migration, matching unit/grammar/e2e tests and pilot docs.
Keep one producer-to-consumer path; remove the superseded representation in
each slice. Update parent GUIDE/GRAMMAR only if their stated semantics change;
the pilot's restricted grammar and README must stay exact.

No multiple type parameters, explicit function type arguments, traits/bounds,
dimensions, higher-kinded types, generic records, managed union fields,
recursive unions, extra runtime arguments, imports, String literals, COW,
general control flow, persistent cache, production tracing or native test
drivers. Do not modify the host compiler or target runtime for this increment.

## Risks and dependencies

The generics worker receives the compiled lane after the coordinator's explicit
tail-validation handback. Serialize builds, sanitizers and measurements, and
release the lane before independent validation. Generic compiler source may expose
host defects: reduce to a small source reproduction and report before a broad
workaround. Keep parser changes within the pilot; this is not a new syntax
change to the full language.

Current unary expression spines run inner-to-outer. Keep their evaluation order
and complete resolved contracts. Bare constructors require contextual types;
do not infer an arbitrary union from a globally repeated variant spelling.
If argument-driven inference cannot meet an example cleanly, report the exact
case and a bounded split. Do not silently special-case `identity`, duplicate
checker paths, or recheck generic bodies at specialization.

## Testing

Start with failing Blorp tests. Add one suite per new implementation module.
Test lexer brackets, parser declaration/type syntax, declaration-owned type
parameters, rigid-body acceptance/rejection, direct/UFCS inference, generic
forwarding, purity, shadowing, uninferable calls, malformed syntax and generic
`main`/prelude rejection. Check exact diagnostics, help and spans.

Direct specialization tests must distinguish same-key reuse, different concrete
arguments, different declarations with same parameter spelling, complete
substitution and call remapping. Cover binding/reassignment types and nominal
unions, not just function headers. Add Int/String lowering, insertion,
independent verifier and emission tests; protect the borrowed-to-owned return
with exact obligation facts. Native fixtures use real `main`, no C rewrites.
The union slice adds payload substitution, exhaustive generic matching,
nominal mismatch and unsupported managed-payload tests.

Prove key oracles by deliberately breaking instance-key argument equality or
String return acquisition, running the relevant focused tests, then restoring
the implementation. Record observed failure; do not retain mutation machinery.

```sh
scripts/compiler-build-status
# If STALE/UNKNOWN: make, then recheck.
bin/blorp test blorp_2/test/unit/test_specialize.brp
bin/blorp test blorp_2/test/test_grammar
bin/blorp test blorp_2/test/unit
bin/blorp test blorp_2/test/e2e
bin/blorp test blorp_2/test/runtime
git diff --check
```

Use normal test arguments and existing O0 settings. The e2e entrypoint builds
the pilot once per run. The coordinator assigns independent code-reviewer and
test-runner review and a focused ASan/UBSan/leak run after stable implementation;
do not spawn a duplicate gate chain. Inspect representative generated C.

## Acceptance criteria

- Both identity instances and generic forwarding execute correctly; union
  wrapping/unwrapping follows as a separately green slice.
- Unused invalid generic bodies fail during checking; no unresolved parameters,
  declaration call targets or spelling-based decisions survive specialization.
- All existing unit, grammar, runtime and e2e checks pass; existing raw malformed
  ownership/match tests remain effective; focused sanitizers are clean.
- Freeze post-tail baseline sources, host/pilot binaries, flags and representative
  inputs before editing. Compare at least three serialized baseline/candidate
  instruction/allocation samples on unchanged scalar, String, tail-String and
  256-arm workloads. Existing e2e ceilings remain. Investigate a repeatable
  increase over 25% on either metric before proceeding; report/rescope rather
  than silently lifting caps. New small fixtures start at 20,000 allocations
  and 200,000,000 instructions, subject to evidence and coordinator review.
- Record C identity or explain necessary identity projection differences;
  verify native results and structural depth. Report production and test LOC
  separately. Measurements are owned-input proxies, not self-compilation claims.

## Release strategy and handback

No commit, push or branch switch. Work in this shared `blorp-2` checkout.
First publish the design map, then function slice evidence, then union slice
evidence. The coordinator reviews each slice and owns integration. Keep raw
artifacts under ignored `build/generics/`; add a concise durable validation
record when done. Maintain this handoff if a reviewed scope decision changes.

Return changed files/contracts, test counts and exact commands, before/after
costs and provenance, generated C paths, LOC, oracle mutation results and
remaining limitations. Explicitly release the compiled lane. Stop and message
the coordinator for scope growth, ambiguous authority, a host defect or cost
ceiling breach; include reproduction, evidence, options and a recommendation.
