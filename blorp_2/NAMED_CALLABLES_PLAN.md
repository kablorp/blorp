# Named pure callbacks

## Problem and scope

The [Option/Result addition plan](OPTION_RESULT_PLAN.md) needs pure callback
semantics before its four callback helpers can be added. Pure function types
already parse, but declaration checking rejects them, named functions are not
values, and local bindings cannot be invoked. Begin with named callbacks over
ordinary data, before lambdas and captures. This is one compiler increment;
no callback library helpers or compiler-source import migration enter it.

B is the accepted ordinary-helper main commit
`5c3e9f3ddc1a51290d1fb0dbbb7e90eb84039586`. Freeze verified host/proxy
identities and the initial source-to-C baseline before the first compiler edit.
No previous helper/HOF-removal epoch or failed observation becomes this baseline.

The first normal-main witness is:

```blorp
pure func identity[T](value: T) -> T:
    value

pure func apply[T, U](value: T, f: pure (T) -> U) -> U:
    f(value)

func main() -> Int:
    apply(17, identity)
```

B rejects the callable annotation. C exits 17 with empty stdout/stderr, using
ordinary direct calls after specialization. Also cover String, embedded NUL,
Void, zero/binary callback arities, named imports, module-qualified references,
and a generic forwarding wrapper. The API is not restricted to unary or final
callback parameters; preserve written data-argument evaluation order.

Callable values are allowed only as arguments to written pure callable
parameters, or as unchanged forwarding of such parameters. They cannot be
stored in locals, returned, placed in records/unions/lists, selected by runtime
branches, or substituted for ordinary data type parameters. Lambdas retain
their current rejection throughout this increment. No function-pointer ABI,
closure runtime, synthesized source, registry or new checking framework follows.

## Fact ownership

| Fact | Producer and owner | Consumer |
| --- | --- | --- |
| Written pure function signature | Existing parser | Signature checking |
| Structural pure callable type | Signature resolution | Inference/equality and checked signature |
| Callable parameter identity | Signature owner plus written position | Scope, invocation and forwarding |
| Named declaration and simultaneous generic substitution | Namespace resolution and expression inference | Checked callable argument |
| Concrete named callback choice | Specialization preparation | Instance keys and direct-call translation |
| Runtime data signature and call | Specialization | Existing Lower, Own, Verify and Emit |

Keep namespace-issued `FunctionId` as the source declaration identity. Do not
manufacture one for a parameter or use a specialization ordinal in its place.
Spans and names remain diagnostic data. Each phase validates once and publishes
complete accepted facts; no inference variable escapes checking.

## Checked model and lexical scope

At `check/model.brp`, add structural `PureCallableType(List[TypeRef], TypeRef)`.
Its parameter and result children are ordinary data types for this increment;
purity is in the variant, not a Boolean. General field/return type resolution
continues rejecting unsupported callable placements. Admit pure callable types
through the function-signature parameter boundary.

Use one opaque `CallableParameterId` consisting of declared owner and original
signature position. Keep it distinct from dense data `BindingId`. Resolve scope
names through precise data/callable alternatives, with both participating in
name conflicts and assignments. A data-local call must retain its current
uncallable-binding error; it must not fall through to an unrelated global.
Do not invent a data binding for a callable error or introduce fake Void slots.

Checked calls retain evaluated data expressions and separate ordered callable
argument metadata:

```text
NamedCallable(source FunctionId, accepted ordinary type arguments)
ForwardedCallable(CallableParameterId)

CallableArgument { parameter: CallableParameterId, choice: CallableChoice }
```

Generalize the existing FunctionContract target identity so invoking `f(value)`
reuses arity/type/first-error machinery while naming a callable parameter
explicitly. Check written arity before erasure. Arity/type diagnostic targets
likewise distinguish a declaration from a callable parameter; never use the
parameter owner as a substitute callee FunctionId. Invocation does not freshen
enclosing rigid parameters: in `forward[T](value:T, f:pure(T)->T)`, `f(0)`
rejects while `f(value)` succeeds. Its accepted signature supplies the result
type and Pure contract.
An impure enclosing caller may still pass only a Pure named declaration to a
pure slot; reject an impure argument at its reference span with teaching help.

`bodies.parameter_scope` currently uses scope length as signature position and
binding ordinal. Replace that coupling with separate written-position and data
ordinal counters. For parameters `value: Int, f: pure(Int)->Int, other: Int`, the
data binding IDs and ParameterBinding origins are 0 and 1; the callable ID names
written position 1. Locals start after the data-parameter count. Every data slot
remains dense and has a real type.

## Inference and publication

Named local/imported/qualified references resolve through existing namespace
identities and visibility rules only when the expected argument slot is
callable. Instantiate each referenced generic signature with fresh local slots,
independent even for a reference to the current declaration. Unify its callable
parameter/result shape with the expected callable term, then freeze its own
simultaneous type substitution. Forwarding preserves its accepted parameter
identity and does not create fresh generic variables.

Extend every existing type observer: equality, parameter occurrence,
substitution, hint projection/merging, readiness, occurs checks and publication.
Preserve accepted-subtree sharing and child-first errors. No observer may treat
a callable composite as an opaque leaf and miss a foreign/unresolved parameter.
Only complete TypeRefs and choices enter the checked product.

Schedule constraints independently from runtime evaluation order. A later typed
data argument may determine a callback's generic parameters; the callback does
not have to appear last. Underconstrained references get an exact inference
error suggesting a typed argument or concrete callback signature.

## Specialization and finite keys

Extend the existing InstanceKey with ordered known callable choices. A choice
contains the source declaration identity and concrete ordinary generic
arguments; retain callable parameter positions in the correspondence. Two
same-typed callbacks, or swapped positions, must create distinct keys. Repeated
identical choices reuse one instance. Resolve forwarding from the current key
and substitute named-reference arguments through the current instance's ordinary
substitution, never by matching names. Preserve reference/use spans and the
existing RequestSource provenance outside semantic key identity. Caller-dependent
request origins must account for callback substitutions, including forwarding,
so a specialization diagnostic keeps its instantiating source origin.

Preparation requests the selected named target as an ordinary function instance.
Translation erases callable parameters and arguments completely; invoking a
parameter becomes an ordinary direct target. ConcreteFunction contains only
existing data types, data bindings and direct/runtime calls. Preserve request
order and exact C for programs without callable parameters. Lower/Own/Verify/Emit
need focused regression assertions, not another callable implementation.

Use an explicit conservative finite-instantiation policy: every named callable
reference is a potential generic-dependency edge, including a reference passed
to a helper that does not invoke it. Feed its published simultaneous substitution
into the existing parameter-growth proof. Forwarded choices do not introduce a
new substitution. Traverse callable type children in that proof.

For example, reject `grow[T](value:T)` passing `grow` to `apply([value], grow)`:
the reference instantiates grow with List[T]. A helper that ignores its callback
does not exempt this potential edge. This is a documented static-subset rule,
not a claim that runtime recursion occurs. Teach the user to pass a callback
whose type arguments do not grow around the cycle. Preserve regular/permuting
finite generic cycles.

Keep potential dependencies separate from actual expression execution.
`function_calls` and tail-call checking must not pretend a named reference ran
at creation. Before body-to-RecurWith conversion, reject `@tail_recursive` on
any function with callable parameters: RecurWith carries data arguments only.
Teach: remove `@tail_recursive`; callable parameters on recursive backedges are
not supported yet. Also reject a named callback reference to the current
annotated function by resolved FunctionId; teach the user to pass a different
callback or remove the annotation. Preserve existing generic/builtin annotation
diagnostic precedence. A reference to an annotated target from another ordinary
function remains valid, as do ordinary recursive calls and unchanged callback
forwarding without the annotation. Never fabricate RecurWith for an indirect
invocation.

## Tests and acceptance

Start with the ordinary witness RED and exact annotation diagnostic. Reuse
existing TestSuite/fixture owners. Tests must include:

- Named generic identity for Int/String/Void, a rigid generic forwarding wrapper,
  zero/binary callback arguments and interleaved data/callable parameters.
- Two equal-signature callbacks and swapped callback slots with different native
  results; repeated identical choices with code-instance reuse.
- Named/imported/qualified lookup, private/unoffered errors, collisions, unknown
  references, data-local calls and exact impure callback rejection.
- Callable storage/return/aggregate/data-type-argument rejection; arity,
  parameter/result mismatch and genuinely underconstrained callback errors.
- Checked identities/substitutions, dense data bindings, erased concrete
  signatures, selected direct targets, and ordinary ownership of managed returns.
- Growing potential reference cycles rejected, preserving/permuting cycles
  accepted, rigid invocation rejecting `f(0)` in a generic forwarding body,
  exact callback/tail-annotation rejections and an unchanged scalar-tail control.

Mutation oracles cover callback-key identity, forwarding, purity and omitted
potential growth edges. Each mutation must fail its owning test and restored
bytes must pass. Native fixtures use their real main, byte-exact output,
unmodified generated C, existing sanitizers, balanced strict allocation counts
and unchanged resource limits. A scoped scratch TestSuite may invoke an existing
owner; it must not add a runner or replace a fixture main.

## Prospective scope and costs

The concrete point forecast is 725 production additions/+560 net, and 450–550
test additions. Hard ceilings, fixed before edits: **900 production additions /
+700 net**, **650 test additions / +600 net**. Report test/production growth
separately and count moves honestly. At 800 additions/+620 net, stop to assess
the remaining work rather than compressing code or deleting coverage. No
preparatory refactor is presently justified.

Freeze a matching current normal/diagnostic host pair, host library, source
inputs, tools/flags and explicit commands. Copy B and C source into pinned,
equal-depth/equal-length `inputs/B/blorp_2/src` and `inputs/C/blorp_2/src`
roots; B stays immutable, C is refreshed only at the accepted candidate freeze.
Use the same working directory and explicit shared host standard library.
This controls path-length work without rewriting emitted C. Verify the
available diagnostic host through the existing Makefile identity path before
use; its old checksum alone
does not establish freshness. Record exactly one observed schema-1 cumulative
`artifact_construction_complete` allocation checkpoint for each diagnostic
source-to-C compile and ordinary minimum-of-three retired instructions separately.
The source label is constructed dynamically by the current phase implementation;
add no instrumentation or historical-schema substitute.

Require independently **C <= 103% of B** for construction allocations and normal
min3 instructions against one initial M7 B. Later lambda increments retain that
same cumulative comparison; no stacking 3% allowances or automatic baseline roll.
Label this host source-to-C measurement as a proxy until self-compilation works.
For the same source variant, normal/diagnostic emitted C must agree; old and new
compiler source need not emit identical C. Unchanged noncallable target fixtures
must still produce byte-identical C. New witnesses use prospective owner limits,
with no fabricated successful B denominator. Keep all existing native caps.

Any repeatable cost/LOC breach, stale pair, malformed checkpoint, ownership
failure or unresolved contract stops the slice for diagnosis and rescoping.
Two independent code/design reviews and test-runner acceptance precede commit,
main integration and push. The next lambda increment must separately settle
nominal lambda identities, immutable captures and complete block return contexts;
it cannot inherit permission for general pending-body inference or a closure ABI.

## Frozen initial M7 epoch

Initial B is `5c3e9f3ddc1a51290d1fb0dbbb7e90eb84039586`. The
[baseline packet](../build/bootstrap-evidence/named-callables-2026-10-18/baseline/)
retains the pre-sample epoch, input manifest, exact commands and raw results.
Both frozen source roots initially contain the same 41 files; the explicit
shared host standard library contains 91 files. The command working directory
is the main checkout. Its `EPOCH.json` fixes absolute input/output paths.

The refreshed supporting host pair uses the existing Makefile. The previous
installed compiler (`c04f68ba…`) is archived before the verified normal host is
installed through the ordinary Makefile freshness path. The install recipe
ad-hoc re-signs its copy; the installed functional host and pre-install
measurement host consequently have separate hashes. The pre-install normal
host already has the linker's ad-hoc signature. Its SHA256 is
`6852e1c6c93b6ee913665fbc72ff4413eb9643c1b51f993ce01a24acaebd36f3`;
diagnostic host SHA256 is
`a362b0dfd7d744b090008b9be405dc0ee5b1dd9437e5ff19d8cf8c516091d774`.
Both report commit `5c3e9f3ddc1a`, clean source, compiled by
`dev-0e1598ed616e`, `aarch64-apple-darwin`, CLI `-O0`, runtime `-O2`,
split 8 and Apple clang 21.0.0. Memory diagnostics differ only as intended,
0 versus 1. Source/C/body-object reuse is verified by hashes and mtimes.

The source-to-C proxy uses `compile --no-format --no-embed-runtime
--time-phases --std-dir <explicit host library> -o <frozen output>
<frozen source>/main.brp`. Separate normal runs use `/usr/bin/time -l`; the
diagnostic run enables `BLORP_MEMORY_STATS=1` for the construction checkpoint.
The existing `self_compile_measure lock --` entrypoint is a passthrough; the
exclusive compiled-job lease provides serialization.

Refreshing the internal normal binary updates the hash referenced by the old
install manifest. This made the unchanged old installed binary report STALE;
that observation is retained. The ordinary install step repairs this boundary
before samples or functional tests. No source, checksum or manifest is patched
to suppress the freshness check.

The signed installed functional host is
`97479b34bcfbf49dfeb269e8cb4e35d4e2757d0b1924ca30ac9c2d95b2db51d9`.
Applying the exact install signing command to an ignored copy of the frozen
pre-install normal host reproduces those bytes. The role transition is explicit
in `INSTALL_ROLE_TRANSITION.json` and `SIGNING_REPRODUCTION.json`; the
measurement pair, source, body objects and tools remain unchanged.

Initial B construction allocations are **24,404,055**. Its three original
normal instruction samples are 44,989,182,994; 44,942,552,001; and
44,935,473,655, giving **44,935,473,655 min3 instructions**. Integer candidate
ceilings are **25,136,176 construction allocations** and
**46,283,537,864 normal min3 instructions**, each independently cumulative
against this initial B. Diagnostic and all three normal runs emit identical C:
`10bfbd0a3046d428076bb9584f0b57001ad38cd7ac0a8cef436145381b186cfa`
(6,690,847 bytes). All 1,536 final pins remain stable.

Setup observations are retained: the pre-install-versus-installed checksum
assumption above, and an evidence wrapper that initially expected empty stdout
rather than the host CLI's exact `Generated <output.c>` line. Validation was
corrected against the original outputs; no compiled observation was retried.
These are setup/evidence corrections, not product failures or gate waivers.
