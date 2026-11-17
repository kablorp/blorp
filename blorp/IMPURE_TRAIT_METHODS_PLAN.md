# Impure trait methods and resource receivers

Plan revision 3, 2026-11-16, against origin/main `4d350add0`, whose line
numbers it cites. It folds in two rounds of soundness and ergonomics review.
The resource-loan hardening is being ported to that main
(`blorp/resource-loans-hardening-3`), so its code is cited by function name,
as at `7672cc3f3`.

Keith set the direction on 2026-11-16:

> A trait does not need to implement pure methods. But if `pure` is
> specified on a trait, it needs to be respected. I think we should probably
> have defaults re-checked for each resource receiver.

This plan reads it as three rules:

1. Trait methods may be impure.
2. A method a trait declares `pure` keeps that contract: no implementation
   may break it, and D35 (no resource in a pure context) still applies to it.
3. A resource type may implement a trait. Each default method it inherits is
   checked again with `Self` taken as that resource, so a default body cannot
   leak the loan.

**Status:** approved by Keith on 2026-11-16, with T1 to T4 as recommended.
Landings 1 and 2 are done (see "Landing 1 results" and "Landing 2
results"); landing 3 is next. Probe outputs (`p01` to `p17`) come
from this tree's compiler ("main") and one built from `7672cc3f3`
("hardened"). Diagnostics marked "proposed" do not exist yet.

## Problem

**Trait methods must be pure.** The parser accepts `func` in a trait; Check
rejects it (`p01`, both compilers; likewise `p02`, a default, and `p09`, a
`Sink` over `Writer`):

```blorp
trait Sink:
    func send(self: Self, text: String) -> Void
```

```text
p01_impure_requirement.brp:2:10: error: trait requirements must be pure
help: declare a pure func requirement and a pure implementation
```

**A resource type cannot implement a trait** (`p10`: hardened, then main,
whose help the contract makes impossible to follow):

```blorp
import:
    io/files/write: Writer

trait Described:
    pure func describe(self: Self) -> String

implements Described for Writer:
    pure func describe(self: Self) -> String:
        "writer"
```

```text
p10_pure_writer_implementation.brp:7:26: error: the resource type Writer cannot implement a trait
help: trait methods are pure, so they cannot take a Writer; write an impure function that takes it instead
```

```text
p10_pure_writer_implementation.brp:8:30: error: pure functions cannot take resource parameters
help: remove pure and consume the resource synchronously
```

**A default is checked once, without the loan.** Admission never sees a
default's `self` as a loan. These compile for a record and run (`p08` exits
4, `p12` exits 1); one returns a closure capturing `self`, the other hands
`self` to a generic function that stores it:

```blorp
trait Later:
    pure func size(self: Self) -> Int
    pure func later(self: Self) -> pure () -> Int:
        pure func() -> Int: self.size()

pure func remember[T](value: T) -> List[T]:
    [value]

trait Kept:
    pure func size(self: Self) -> Int
    pure func kept(self: Self) -> Int:
        remember(self).length()
```

Made impure and inherited by a resource, each would let the loan outlive
its scope, and neither signature shows it.

## Background

All changes are in Check (`src/common/analysis/check/`), which accepts trait
contracts, then signatures and implementation headers, then implementations,
then each body and its admission walk (`check.brp:analyze_program`). No later
phase reads purity or resources. References: `README.md` "Traits" and its
resource paragraph; `FILESYSTEM_DECISIONS.md` D31, D35 and the hardening
amendment.

| Fact today | Evidence |
| --- | --- |
| A trait method's `pure` is optional in the grammar | `grammar.ebnf:736`, `parse.brp:5278` |
| Check rejects impure requirements, recording each as `Pure` | `traits.brp:157-160`, `:234` |
| A method call checks arity, not purity | `callables.brp:450-459` |
| Canonical shapes omit purity; their messages say "pure" | `traits.brp:447` |
| Implementations match purity exactly | `traits.brp:904` |
| A default has its own bounded `Self` and is checked once | `resolve_default_function` |
| Resource implementations are rejected at the receiver | hardened `implementation_header` |
| Admission reads types; `ParameterType` is never a resource | hardened `as_resource` |
| A method receiver is admitted as a type argument | hardened `admit_call`, `admit_choice`; `p04` |
| A generic given a resource is rejected at the call | `p05`; `p11`, bounded |
| A generic value cannot be matched | `p06` |
| A default may hold `pure func(value: Self)` | `p07` exits 6 |
| A method value is a valid argument; stored, a purity mismatch is a type error | `p13`; `p14` |

## Decisions for Keith

- **T1. Must an implementation match its requirement's purity exactly?**
  *Recommended: yes, exactly, as today.*
  - Exact matching costs no code and keeps one purity per method, so no
    call is rejected as impure while the receiver's method says `pure`.
  - The alternative lets a pure implementation satisfy an impure
    requirement, as callable values allow (`expressions.brp:853`) and Swift
    a non-throwing witness for `throws`, but calls through the method stay
    impure. It changes one comparison in `member_contract`; the mismatch
    error must then say which side is impure, and `ImpureCall` on a method
    needs a note that calls through it are impure.
- **T2. May an impure requirement take a resource parameter?**
  *Recommended: yes,* as for every signature (`resolve_signature`).
  Refusing it keeps a rule D35 does not state, under a false message
  ("pure functions cannot take …").
- **T3. Where is a resource's pure method rejected?** *Recommended: at the
  implementation's receiver, over the trait and every trait above it,
  naming the method.* At the user's method, removing `pure` breaks the
  contract (the hardening's complaint); including supertraits saves a step.
- **T4. How are inherited defaults checked again?** *Recommended: walk the
  default's checked body again per inheriting resource, reading `Self` as
  that resource.* Rejected:
  - *Re-elaborating with `Self` as the resource* checks another program
    than specialization runs: given `close[T](value: T)` and
    `close(reader: Reader)`, `self.close()` means the first generically but
    may mean the second, or be ambiguous, for a Reader.
  - *Checking instances in specialization* breaks rule 8 and misses
    unreached defaults.
  - *Forbidding inherited defaults* is sound and smaller, but not what Keith
    asked for.

**Notes, not choices.** Keith's "probably": the re-check is what he asked
for. The record: D41, in a new dated section of `FILESYSTEM_DECISIONS.md`,
supersedes the hardening's interim rule; no dated text is edited.

## Proposed solution

### Landing 1: impure trait methods

- **Requirements** keep their written purity; `ImpureRequirement` is
  deleted. Defaults already take their requirement's purity.
- **Implementations** match purity exactly (T1).
- **Calls:** `method_contract` takes the `Caller` and rejects a pure
  caller's receiver, named or qualified call to an impure method.
- **Method values** have their requirement's purity
  (`method_callable_operand`). An impure one passed for a pure callable is
  rejected like a function; stored first, the mismatch stays a type error
  (`p14`).
- **One vocabulary:** `ImpureCall` and `ImpureCallback` name an
  `ImpureCallee`, a function or a method, rather than gaining method twins.
- **Families and supertraits:** purity belongs to the requirement, the same
  for every receiver. A trait may mix purities with its supertraits; no
  implementation defines a supertrait's method, so purities never compete.
- **Library traits stay pure,** `Hashable` included. Operators and
  interpolation call canonical members (`Equatable`, `Orderable`, the
  arithmetic traits, `Stringable`) from pure code unchecked, so `has_shape`
  requires `Pure`. A Dict's pure functions need a deterministic `hash`.
- **No false statements remain.** The hardening's `ResourceImplementation`
  help and README sentence blame purity; until landing 2 they say "not yet".

### Landing 2: resource receivers

**Calls on a resource receiver.** A trait method's receiver, in a call or a
method value, is admitted when it is a whole resource and refused, as today,
when it only mentions one. A user generic still never takes a resource:
`announce[T: Sink](sink: T)` called with a Writer keeps the hardened message
(`p05`), whose help says to call functions that take it directly.

`Self` is sound where `T` is not: admission proves a loan safe by walking a
body with the resource in view, and every body receiving a resource as
`Self` is walked so. An authored method is resolved with `Self` as the
resource, an inherited default is walked again (below), and a call on
`self` reaches another such body. A user generic's body is walked once, with
`T` rigid.

**Pure methods (rule 2).** For a resource receiver, `implementation_header`
reads `Self` as the resource in each method of the trait and every trait
above it. Each signature must pass a declared function's rules: D35 for a
pure method, and no other parameter or result holding the resource. A
failure is `ResourceContract` at the receiver, noted at the trait's
signature; it replaces `ResourceImplementation`. Running before any body,
it ensures no method callable on a lent `self` returns the resource.

**Inherited defaults (rule 3).**

1. *Which.* `resolve_functions` derives `ResourceDefault` rows once from
   the accepted implementations: each `TraitDefault` member of one for a
   resource. A row names the method, whose `default_body` is the body. The
   list is empty for the compiler itself.
2. *When.* Right after a default's own admission, its `ResolvedBody` is
   walked again per row. Nothing is stored or re-inferred.
3. *Written types.* In lent mode the walk first admits every binding's type,
   in the body and in each lambda it enters, and each lambda's result, as if
   written, and refuses a pure lambda's resource parameter. Elaboration
   applies these rules to written types (`resolve_type`, `lambda_scope`);
   `p07` shows a default can hold `pure func(value: Self)`.
4. *How.* `Admission` gains `lent_self`, and the walk's eight type tests
   read types through `Self` → the resource (`substitute_type`). Calls on
   `self` pass the receiver rule. The walk rejects, as for any resource,
   also inside `?=` and `match`: returning or binding `self`; putting it in
   a record, tuple, List, variant or update; returning, storing or passing
   unscoped a closure that captures it; a pure closure capturing it; giving
   it to a generic function or function value. `match self` fails earlier
   (`p06`).
5. *Why view, not substitute once:* substituting rewrites every expression
   form and lambda row, a second exhaustive walk. Viewing touches eight type
   tests, and the ordinary walk gets an inline `Result` from a `None` match.
6. *Diagnostic:* at the accepted row's span, the header; a note gives the
   broken rule at the default's line; the help, chosen by that rule, says
   how to override the trait author's default or not implement the trait.
   `ResourceContract` uses the receiver span `implementation_header` holds,
   so neither needs a join or a field.

**What the interim rule becomes.** `ResourceImplementation` is deleted. Its
two hardening tests use `pure` methods, so neither flips to accepted; they
become `test_resource_cannot_be_self_of_a_pure_method` and
`test_resource_cannot_inherit_a_pure_default`, expecting `ResourceContract`.

### Landing 3: resource-aware helps

Three helps, deferred by the hardening, advise what a resource cannot do
(`p15` to `p17`). Each error carries the receiver and the trait.

- `InterpolationRequiresStringable` ("implement Stringable for …"): the help
  says Stringable is pure.
- `MissingImplementation` ("declare a matching implementation"): when the
  trait declares a pure method, the help names it. `RenderContext` holds no
  accepted traits (`render.brp:88-91`), so a pure method only in a
  supertrait keeps today's help, and implementing the trait then reports
  `ResourceContract`; a test pins that path.
- `MissingTraitBound` comes from a generic call's bound proof (`p15`), where
  implementing the trait cannot help, so the help says generics never take
  a resource.

### Documents, seed and bootstrap

- README "Traits" gains the four rules drafted under "Code": two in landing
  1, two in landing 2, which drops the resource paragraph's sentence.
  Landing 1 makes `grammar.ebnf:720` say "nongeneric signatures; a pure
  method takes no resource".
- Landing 2 adds "Resource types and traits, 2026-11-16" to
  `FILESYSTEM_DECISIONS.md`: Keith's words, D41 and the costs.
- `NEXT.md` indexes this plan until the last landing.
- No landing touches the library or the compiler's source, so none needs a
  rotation. The seed rejects impure methods and, after the hardening,
  resource implementations, so a module the compiler imports adopts either
  only after a seed with the enabling landing is pinned.

## Code

### Landing 1

**`traits.brp:148`, `requirement`.** The purity gate (`:157-160`) goes, the
pure-parameter refusal (`:184-191`, `refuse_resource` after the hardening)
applies only to a pure requirement (T2), and the signature keeps its written
purity (`:234`):

```blorp
            Ok(ResolvedTypeTerm(value_type, parameter_uses)):
                -- D35: only a pure method keeps resources out of its parameters.
                if (header.purity == Pure).and(value_type.is_resource(scope.opaques)):
                    failure = Some(
                        resource_errors.resource_error(
                            parameter.type_name.type_span(),
                            resource_errors.ResourcePureParameter,
                        ),
                    )
                    break
    …
                purity = header.purity,
```

**`traits.brp:447`, `has_shape`.** The existing "requires pure …" messages
become true:

```blorp
-- Operators and interpolation holes call canonical members from pure code
-- without a purity check, so a canonical member must be pure.
private pure func has_shape(method: AcceptedTraitMethod, shape: MemberShape) -> Bool:
    (method.signature.purity == Pure).and(
        (method.signature.parameters.map(pure func(parameter): parameter.value_type) == shape.parameters).and(
            method.signature.return_type.value_type == shape.result,
        ),
    )
```

**`errors.brp:314`, `:319`.** One callee vocabulary:

```blorp
-- What a pure body called, or was given as a pure callback, that is impure.
-- A method's purity is its requirement's, whatever the receiver.
fixed union ImpureCallee:
    CalledFunction(FunctionId)
    CalledMethod(TraitMethodId)

    ImpureCallback(ImpureCallee)
    ImpureCall(BodyOwner, ImpureCallee)
```

**`callables.brp:450`, `method_contract`.** Its callers (`callables.brp:379`,
`expressions.brp:1578`, `:4942`) pass `context.caller`; `validate_purity`
(`:170`) wraps its callee in `CalledFunction`.

```blorp
pure func method_contract(
    caller: Caller,
    name: WrittenName,
    count: Int,
    receiver_call: Bool,
    method: TraitMethodId,
    traits: AcceptedTraits,
) -> Result[FunctionContract, CheckError]:
    contract ?= method_id_contract(name.span, method, traits)
    arity ?= validate_arity(name, receiver_call, count, MethodTarget(method), contract.signature)
    if caller.calls_impure_from_pure(contract.signature):
        Err(call_error(name.span, ImpureCall(caller.body, CalledMethod(method))))
    else:
        Ok(contract)
```

**`expressions.brp:870`, `callable_permission`**, beside the function arm:

```blorp
                                PendingMethodCallable(method, signature, _):
                                    if signature.purity == Pure:
                                        Ok(value)
                                    else:
                                        Err(call_error(value.span, ImpureCallback(CalledMethod(method))))
```

**Proposed diagnostics.** `render.brp` spells `Logger.log` from the trait
inventory.

```blorp
trait Logger:
    func log(self: Self, text: String) -> Void
    func log_all(self: Self, lines: List[String]) -> Void:
        for line in lines:
            self.log(line)
        void

record Console { prefix: String }

implements Logger for Console:
    func log(self: Self, text: String) -> Void:
        print("${self.prefix}${text}")

pure func quiet[T: Logger](logger: T) -> Int:
    logger.log("x")
    0

func each(console: Console, callback: pure (Console, String) -> Void) -> Void:
    callback(console, "x")

func main() -> Int:
    each({ prefix = "> " }, log)
    0
```

Check reports the first; without it, the second (`p13` confirms the
argument's spelling):

```text
main.brp:14:12: error: pure functions cannot call the impure method Logger.log
help: remove pure from the caller, or call a pure method instead
main.brp:21:29: error: pure callback requires a pure method, and Logger.log is impure
help: pass a pure function, or make the callback's type impure
```

**Hardening text,** the help and the README sentence:

```text
help: resource types cannot implement traits yet; write an impure function that takes a Writer instead
A resource type cannot implement a trait yet.
```

**README "Traits"** (887-913), first paragraph and rules:

```markdown
A trait declares methods whose first parameter is `Self`, each `pure` or
not. A signature without a body is required; one with a body is a default.

- An implementation matches each method's parameters, result and purity.
- A call through a method has the purity its trait declares, for every
  receiver and bound, and so does a method used as a function value: a pure
  function calls only pure methods.
- A resource type may implement a trait only if every method it would be
  `Self` of, the trait's and its supertraits', is impure and holds the
  resource nowhere but whole parameters.
- A default a resource type inherits is checked with `Self` as that
  resource: it may not return, store or capture it, or pass it to a generic
  function.

Operators and interpolation call methods of the prelude's traits, which must
be pure.
```

### Landing 2

**`errors.brp`.** The three scoped rejections become one variant, so a lent
misuse names either kind without nesting `ResourceError`, and the resource
is named once. `ResourceImplementation` is deleted:

```blorp
fixed union ScopedUse:
    ScopedResult
    ScopedStorage
    ScopedArgument


-- What Self did once read as a resource.
union LentMisuse:
    LentResource(ResourceUse)
    LentScoped(ScopedUse)


-- A method of `implemented`, or of a trait above it, whose signature puts
-- the resource where `use` forbids; `at` is in that trait.
record LentContract {
    resource: OpaqueId,
    implemented: TraitId,
    method: TraitMethodId,
    use: ResourceUse,
    at: Span,
}


-- An inherited default that misuses the resource; `at` is in the default.
record LentDefault {
    resource: OpaqueId,
    method: TraitMethodId,
    misuse: LentMisuse,
    at: Span,
}

union ResourceError:
    MisusedResource(OpaqueId, ResourceUse)
    MisusedScoped(ScopedUse)
    ResourceContract(LentContract)
    InheritedDefault(LentDefault)
    …

union CheckerInvariant:
    …
    -- A check with Self read as a resource rejected something other than it.
    UnlentRejection
```

`LentContract.use` stays a `ResourceUse`, though the header produces four of
its cases: a narrower union would repeat them, and render prints any case
correctly.

**`signatures.brp`, `implementation_header`,** given the accepted traits
`validate_signatures` holds. Resource implementations are rare, so testing
every trait with `entails` is cheap enough:

```blorp
    _: Void ?= match head:
        OpaqueHead(id):
            lent ?= id.declared_resource(scope.opaques, receiver_span)
            match lent:
                Some(resource):
                    owner ?= scope.namespace
                        .implementation_trait(row.header.module, row.id)
                        .or_checker_invariant(receiver_span, InvalidFunctionContract)
                    traits.admit_lent_contract(resource, owner, scope.opaques, receiver_span)
                None:
                    Ok(void)
        PrimitiveHead(_) | ListHead | UnionHead(_) | RecordHead(_):
            Ok(void)


-- A resource is Self of every method of its trait and of each trait above
-- it. Read with Self as the resource, each signature must pass a declared
-- function's rules: D35 keeps it out of a pure method's parameters, and no
-- other parameter or result may hold it.
private pure func admit_lent_contract(
    traits: List[AcceptedTrait],
    resource: OpaqueId,
    implemented: TraitId,
    opaques: List[OpaqueRow],
    receiver_span: Span,
) -> Result[Void, CheckError]:
    var admitted: Result[Void, CheckError] = Ok(void)
    for candidate in traits:
        if admitted.is_ok().and(traits.entails(implemented, candidate.id)):
            lent: Substitution = {
                owner = TraitDeclaration(candidate.id),
                values = [NominalType(OpaqueNominal(resource), [])],
            }
            for method in candidate.methods:
                if admitted.is_ok():
                    admitted = method.signature
                        .admit_lent_signature(lent, opaques)
                        .map_err(pure func(error): error.as_lent_contract(resource, implemented, method.id, receiver_span))
    admitted


-- Substitutes, then applies `refuse_resource` (`ResourcePureParameter` to a
-- pure method's parameters, `ResourceResult` to the result) and
-- `admit_resource_type` at each type's span.
private pure func admit_lent_signature(
    signature: FunctionSignature,
    lent: Substitution,
    opaques: List[OpaqueRow],
) -> Result[Void, CheckError]


-- `MisusedResource(resource, use)` becomes `ResourceContract`. Requirement
-- acceptance already refused every other resource a signature could hold,
-- so any other resource rejection is `UnlentRejection`, a checker defect;
-- other invariants pass through.
private pure func as_lent_contract(
    error: CheckError,
    resource: OpaqueId,
    implemented: TraitId,
    method: TraitMethodId,
    receiver: Span,
) -> CheckError
```

**`resource_scopes.brp`.** The receiver rule, which `admit_call` and
`admit_choice` call for `TraitMethod` and `MethodCallable`:

```blorp
-- A method's receiver is Self, not a type argument a generic body could keep:
-- every body that receives a resource as Self is walked with it in view.
private pure func admit_receiver(
    admission: Admission,
    receiver: TypeRef,
    span: Span,
) -> Result[Void, CheckError]:
    seen ?= admission.viewed(receiver, span)
    whole ?= seen.as_resource(admission.opaques, span)
    match whole:
        Some(_):
            Ok(void)
        None:
            seen
                .type_children()
                .first_mentioned(admission.opaques, span)
                .refuse(span, errors.ResourceInferredType(seen))
```

The lent view, read by `admit_binding`, `admit_return`, `admit_match_root`,
`admit_stored`, `admit_type_arguments`, `admit_closure`, `admit_lambda` and
`admit_construction`:

```blorp
private record Admission {
    opaques: List[OpaqueRow],
    functions: List[AcceptedFunction],
    lambdas: List[model.LambdaRow],
    -- Set when an inherited default is walked again: its Self, as the resource.
    lent_self: Option[Substitution],
}


private pure func viewed(admission: Admission, value_type: TypeRef, span: Span) -> Result[TypeRef, CheckError]:
    match admission.lent_self:
        None: Ok(value_type)
        Some(lent): value_type.substitute_type(lent, span)
```

For example, the end of `admit_return`:

```blorp
        returned ?= admission.viewed(value.value_type, value.span)
        returned.refuse_resource(admission.opaques, value.span, errors.ResourceResult)
```

The rows and the second walk. `body` is the function `resolve_functions` is
checking, found as the row method's `default_body`:

```blorp
-- A default that an implementation for a resource inherits, reported at that
-- implementation. Derived once from the accepted implementations.
record ResourceDefault {
    resource: OpaqueId,
    method: TraitMethodId,
    implementation: Span,
}


-- Walks a default again for one resource that inherits it, reading its Self
-- as that resource: the first walk could not see the loan.
pure func admit_resource_default(
    body: model.ResolvedBody,
    default_body: FunctionId,
    inherited: ResourceDefault,
    return_type: TypeRef,
    functions: List[AcceptedFunction],
    opaques: List[OpaqueRow],
) -> Result[Void, CheckError]:
    admission: Admission = {
        opaques = opaques,
        functions = functions,
        lambdas = body.lambdas,
        lent_self = Some({
            owner = FunctionDeclaration(default_body),
            values = [model.NominalType(model.OpaqueNominal(inherited.resource), [])],
        }),
    }
    _: Void ?= admission.admit_written_types(body.bindings)
    admission
        .admit_completed_body(body, return_type)
        .map_err(pure func(error): error.as_lent_default(inherited))
```

Both walks share `admit_completed_body`, today's `admit_resource_body` body.
In lent mode `admit_lambda` also admits its bindings' types and result and
refuses a pure lambda's resource parameter. `as_lent_default` maps
rejections as `as_lent_contract` does, keeping scoped ones as `LentScoped`.

**`bodies.brp`, `resolve_functions`,** beside `has_resources`:

```blorp
    inherited: List[ResourceDefault] ?= if has_resources:
        traits
            .accepted_traits().implementations
            .implementation_rows()
            .resource_defaults(opaque_declarations)
    else:
        Ok([])
    …
                                    body
                                        .admit_resource_body(signature.return_type.value_type, functions, opaque_declarations)
                                        .and_then(pure func(_): inherited.admit_inheritors(id, body, signature.return_type.value_type, functions, opaque_declarations, traits))
```

**`render.brp`.** `render_resource_error`'s message arms become one
function, `misuse_message`, shared with the notes, so no wording is new. The
help is one `match`:

```blorp
    fix = match misuse:
        errors.LentScoped(_) | errors.LentResource(errors.ResourcePureCapture):
            "without a closure that captures the ${resource}"
        errors.LentResource(errors.ResourceInferredType(_)) | errors.LentResource(errors.ResourceTypeArgument):
            "and pass the ${resource} only to functions that take a ${resource}"
        errors.LentResource(errors.ResourceResult) | errors.LentResource(errors.ResourceStorage):
            "without returning or storing the ${resource}"
        errors.LentResource(errors.ResourcePureParameter):
            "without a pure lambda that takes the ${resource}"
    help = "write ${method} in this implementation ${fix}, or do not implement ${trait} for ${resource}"
```

**Proposed diagnostics.**

```blorp
resource type Token = Int

trait Later:
    func size(self: Self) -> Int
    func later(self: Self) -> () -> Int:
        func() -> Int: self.size()

implements Later for Token:
    func size(self: Self) -> Int:
        from_opaque Token(self)

func main() -> Int:
    0
```

```text
main.brp:8:1: error: the resource type Token cannot use Later's default later
help: write later in this implementation without a closure that captures the Token, or do not implement Later for Token
main.brp:6:9: note: in Later's default, with Self as Token: scoped callables cannot be returned
```

`p10`'s `Described for Writer`, then the same method reached through a
supertrait:

```text
p10.brp:7:26: error: the resource type Writer cannot implement Described
help: declare describe without pure in Described, or write an impure function that takes the Writer instead
p10.brp:5:30: note: in Described.describe: pure functions cannot take the resource type Writer
```

```blorp
import:
    bytes: Bytes
    io/files/write: Writer, WriteError, write_all

trait Described:
    pure func describe(self: Self) -> String

trait Sink: Described:
    func send(self: Self, data: Bytes) -> Result[Void, WriteError]

implements Sink for Writer:
    func send(self: Self, data: Bytes) -> Result[Void, WriteError]:
        self.write_all(data)
```

```text
main.brp:11:21: error: the resource type Writer cannot implement Sink
help: declare describe without pure in Described, or write an impure function that takes the Writer instead
main.brp:6:30: note: in describe, inherited from Described via Sink: pure functions cannot take the resource type Writer
```

A library trait cannot drop `pure`, so its help keeps the alternative; a
failure other than purity, such as `-> (Self, Int)`, names the result:

```blorp
resource type Token = Int

implements Stringable for Token:
    pure func to_string(value: Self) -> String:
        "token"
```

```text
main.brp:3:27: error: the resource type Token cannot implement Stringable
help: write an impure function that takes the Token instead
<standard library>/_base.brp:84:32: note: in Stringable.to_string: pure functions cannot take the resource type Token
help: change pair in Pairs so that the Writer is not its result or part of a List, tuple or record, or write an impure function that takes the Writer instead
```

### Landing 3

Render reads the receiver's opaque row and the trait's own methods from the
parsed inventory. Proposed helps for `p17`, `p16` and `p15`:

```text
help: Stringable.to_string is pure, so a Token cannot implement Stringable; interpolate a value read from the Token instead
help: Marked.mark is pure, so a Token cannot implement Marked; call a function that takes the Token instead
help: generic functions cannot take a Token; call functions or methods on the Token directly instead
```

## Landings

1. **Landing 1, impure trait methods,** with its README rules and grammar
   comment. If the hardening is not on main yet, its port takes the
   reworded text instead.
2. **Landing 2, resource receivers,** after the hardening lands, with the
   last two README rules and D41.
3. **Landing 3, resource-aware helps.**

Each is reviewed for one concern: purity, loans, wording. Landing 2 must not
reach a release without landing 3, because it makes the old helps wrong in
more programs.

## Ceilings

Upper bounds, measured with `blorp/scripts/self-compile-cost BASE CANDIDATE
--rounds 5` against each landing's parent. Budget corrections are the
coordinator's, recorded here with old and new figures.

Which row binds: the fixed-input rows isolate the change's cost; the
own-source rows also grow with the compiler's own source. Landing 1's
own-source allocation row (+0.1040%) exceeds +0.05% for that reason alone.

**Which row the cost ceilings bind (coordinator, 2026-11-16).** The
instruction, allocation and peak heap ceilings bind the fixed-input row, where
both compilers compile the base's source, so only the compiler differs. The
own-source row is reported but not held: each revision compiles its own,
longer source, and added source alone costs about 0.3% per 100 lines
(`UINT8_BYTES_PLAN.md`, L1). Landing 1 showed why: on the fixed input its
allocations were unchanged and its instructions fell 0.04%, while on its own
source, 73 lines longer, allocations rose 0.10%.

| Landing | Instructions | Allocations | Peak heap | Production lines | Test lines |
| --- | --- | --- | --- | --- | --- |
| 1 | +0.1% | +0.05% | +0.1% | +80 net | +450 |
| 2 | +0.15% | +0.05% | +0.1% | +447 net | +700 |
| 3 | +0.05% | +0.05% | +0.1% | +50 net | +150 |

- **Landing 1** adds a purity comparison per method call and canonical
  member. Estimate: +50 net lines, `render.brp` +30 of them.
- **Landing 2** adds no walk to a self-compile, but the existing walk
  matches `lent_self` at each type test. Estimate: +275 net
  (`resource_scopes.brp` +125, `signatures.brp` +70, `render.brp` +45,
  `errors.brp` +25, `bodies.brp` +10). The coordinator lowered revision 2's
  +360 ceiling to +300 after a growth audit dropped the closure walk, the
  receiver-span join and the help machinery. Keith raised it from +300 to
  +447 on 2026-11-16, after the review's audit of the built code: the
  estimate missed formatter wrapping, the error mapping and the specified
  diagnostics, and reaching about +350 would have dropped plan behaviour,
  including the lent-mode written-type check that keeps `pure` respected
  inside defaults.
- **Landing 3:** +35 net, in `render.brp`.

## Landing 1 results

Measured with `blorp/scripts/self-compile-cost 8f1ee3054 <candidate>
--rounds 5` on macOS, -O2 as the script builds it. The base is `8f1ee3054`
(origin/main, after the resource-loan hardening). The candidate's source is
identified by its trees: `blorp/src` `764cc8f5b31dcaa12cd3dd725df1f8dfca0f09d6`
and `blorp/standard_library` `b950352fd8e5b0bde020194d1795fad26b348147`,
identical to the measured revision's. Raw samples:
`build/impure-trait-methods/landing-1/` in the main checkout.

| Metric | Base | Candidate | Change |
| --- | --- | --- | --- |
| Fixed input allocations | 14,176,929 | 14,176,929 | +0.0000% |
| Fixed input peak heap, bytes | 170,239,903 | 170,239,903 | +0.0000% |
| Fixed input instructions (median of 5) | 12,635,250,744 | 12,630,139,157 | -0.0405% |
| Own source allocations | 14,176,929 | 14,191,674 | +0.1040% |
| Own source peak heap, bytes | 170,239,902 | 170,381,790 | +0.0833% |
| Own source instructions (median of 5) | 12,626,488,286 | 12,638,920,897 | +0.0985% |

The fixed-input C is identical (`51cbd4fb7ff3fecb`), so the change costs a
compile of the same program nothing. The own-source rows compile a compiler
whose source is 73 production lines longer, and exceed the allocation ceiling
only through that input growth (see the note under Ceilings).

The e2e case's ceilings are the measured cost plus 15%: 115,436 allocations
(132,751) and 388,436,320 instructions (446,701,768).

Lines against origin/main: production `blorp/src` +99 -26 (+73 net); tests
+436 net (`test_trait_purity.brp` 385, `control.brp` 12, fixture 38,
`driver.brp` 1, `test_resource_scopes.brp` 0 net).

Mutation proofs (each restored): removing the `has_shape` purity test fails
the three canonical tests; removing `method_contract`'s check fails the five
call tests, the alias test and the supertrait test; removing the
`callable_permission` method arm fails the pure-callback test; removing the
T2 guard fails the accepted-methods test; recording `Pure` in `requirement`
fails the accepted tests and the pure-implementation mismatch test; skipping
the purity comparison in `member_contract` fails both mismatch tests.

## Landing 2 results

**Production lines: +447 net,** at the ceiling Keith set on 2026-11-16 (raised
from +300; see "Ceilings"). The cost ceilings hold. "Lines" below gives the
breakdown.

Measured with `blorp/scripts/self-compile-cost 4fee244ad <candidate>
--rounds 3` (origin/main at the time) on macOS, Darwin 25.6.0 arm64, Apple
clang, -O2 as the script builds it, seed `blorp-seed-93798484557c`. The
candidate's source is identified by its trees: `blorp/src`
`c387c6c64a2de5d2a1a7de405d2bc4e45429af2b` and `blorp/standard_library`
`b950352fd8e5b0bde020194d1795fad26b348147`, the base's. Raw samples are in
`build/impure-trait-methods/landing-2/amended/` in the main checkout, beside
the mutation runner and its results, the fixture compiles, and
`first-measurement/` (five rounds against `ec0166cf6` before review: fixed
input instructions +0.0350%, allocations and peak heap unchanged).

| Metric | Base | Candidate | Change |
| --- | --- | --- | --- |
| Fixed input allocations | 14,211,981 | 14,211,981 | +0.0000% |
| Fixed input peak heap, bytes | 170,460,277 | 170,460,277 | +0.0000% |
| Fixed input instructions (median of 3) | 12,674,159,474 | 12,680,118,280 | +0.0470% |
| Own source allocations | 14,211,981 | 14,315,638 | +0.7294% |
| Own source peak heap, bytes | 170,460,276 | 171,313,404 | +0.5005% |
| Own source instructions (median of 3) | 12,665,180,231 | 12,759,473,869 | +0.7445% |

The fixed-input C is identical (`77769152f5dc23d3`), and all four strict
runs balance with no leak. The compiler declares no resource
implementation, so it derives no `ResourceDefault` row and never walks a
body twice. The fixed-input cost is the `lent_self` match at each type test
and, since review, one trait lookup per implementation header. The
own-source rows compile a compiler 447 production lines longer.

The e2e case `resources/traits` compiles in 117,948 allocations and
400,848,658 instructions (median of 5); its ceilings are those plus 15%,
135,641 and 460,975,957. After review it measured 117,948 and 400,709,703. Its C passes the Token as `int64_t` throughout: the
`with_token` lambda calls the inherited default `report` as
`blorp_f_5(int64_t, struct blorp_string*)` and the authored `count` as
`blorp_f_6(int64_t)`, and `report` calls `blorp_f_6` directly.

**Lines** against origin/main, after `blorp format`: production `blorp/src`
+638 -191 (+447 net); tests +628 net (`test_resource_scopes.brp` +556 net,
fixtures 59, `surface.brp` 13). By file, net: `resource_scopes.brp` +170,
`render.brp` +102, `signatures.brp` +95, `errors.brp` +57,
`resource_types.brp` +14, `bodies.brp` +10, the `entails` move from
`traits.brp` to `model.brp` 0 (traits' imports -4), others -1. Review cut
19 lines of slack and the `admitted` guard on `entails` added 4, from +462.
Against the estimate (+275), the differences are mostly the formatter's
wrapping of long chains and calls, two diagnostics with notes and
rule-chosen helps (`render.brp`), and the lent-type admission for bindings,
results and pure lambda parameters (`resource_scopes.brp`). The review's
growth audit found +300 out of reach without dropping plan behaviour.

**Departures from "Code → Landing 2".**
- `resource` is a reserved keyword, so the records' field is
  `resource_type`.
- `entails` moved to `model.brp`, beside `AcceptedTrait`: `signatures.brp`
  cannot import `traits.brp`, which imports it.
- `?=` cannot appear in a `match` arm, so the header check finds the
  resource and the implemented trait first, as `accept_implementation`
  does, then matches.
- `ResourceDefault` also holds `default_body`, the body its `TraitDefault`
  member names, so matching a row to the function being checked needs no
  lookup that could miss. `admit_resource_body(body, id, signature,
  functions, opaques, inherited)` runs the first walk and then one walk per
  row whose default is this body.
- `errors.lent_misuse` classifies a rejection made with `Self` read as the
  resource, for both the header and the second walk, and is where
  `UnlentRejection` arises. `errors.scoped_error` builds a `MisusedScoped`
  rejection. `resource_types.admit_as_written` is the one written-type
  admission both use.
- A library trait is any trait outside a user module (`Stringable` is in a
  foundation module). The "declare … without pure" help is chosen by the
  method's written purity, since a pure method always fails first at its
  `Self` parameter: an impure method whose result is a pure callable taking
  `Self` gets the "change …" help instead.
- The lent walk also admits the default's own result as written, which the
  header check already did; the same function serves each lambda.
- A note about a lambda's result is at the whole lambda, the span the
  checked lambda keeps for its result.
- The e2e case is in `surface.brp`, beside the other resource case.

**Mutation proofs** (each built and run alone, then restored):
- the header check off fails the seven `ResourceContract` tests; without
  supertraits, the supertrait test; without D35's refusal, the four pure
  ones; the library help off, the Stringable test; the method's purity
  ignored, the pure-callable-result test and, after review's simpler choice,
  the two other non-purity contract tests; the supertrait note's wording
  off, the supertrait test. The first, second and purity mutations were
  rerun on the reviewed code;
- with no row walked, all fifteen `InheritedDefault` tests fail. Each view
  off fails its routes: binding, "bind Self"; construction, "put Self in a
  List"; type arguments, the generic function, generic function value and
  `?=` tests; closure captures, the five closure tests; lambda result,
  "return Self from a lambda";
- written types of the body off fails the binding-type test; of each
  lambda, the lambda binding, lambda result and pure lambda tests; the
  lambda result alone, its test; the pure lambda refusal alone, its test;
- the receiver rule reverted fails the five acceptance tests and the four
  closure tests, whose closures call `self.size()`; unviewing the receiver
  fails the same nine, because `admit_type_arguments` then views `Self`;
- scoped misuses left unmapped fail the four scoped closure tests;
- the lent view under the wrong owner fails all twenty tests that walk a
  default again, so `substitute_type` fails closed;
- generic calls' type arguments unchecked fails the bounded generic test,
  the two generic default tests and two older tests;
- the return, match-root and stored views, and `UnlentRejection`'s resource
  check, fail no test: no source program reaches them, since the header
  check and the earlier type tests catch every route first. They keep the
  walk failing closed.

## Follow-ups from landing 1's review

- **Landing 2** (same files): `method_contract` repeats `validate_purity`'s
  if/else; make `validate_purity` take an `ImpureCallee`. Rename `refused` to
  `admitted` in `requirement`.
- **Landing 3** (wording):
  - `ImpureCall`'s help "remove pure from the caller" leads nowhere for a pure
    implementation member: following it gives `ImplementationSignatureMismatch`.
  - "pure callback requires a pure method" also shows for constants, returns
    and fields.
  - `MalformedCanonicalTrait`'s help for an impure abstract `equals` never
    says to add `pure`.

## Scope and non-goals

- Not in scope: generic resource types or resource type arguments; `scoped`
  in requirements (D31); callable formals; impure canonical traits; library
  traits for `Reader` or `Writer`.
- Found in passing: `ImpureRequirement` has no test, and canonical purity
  was never checked; landing 1 covers both.

## Risks and unknowns

- **A route the lent walk misses.** Landing 2 tests each route, and its
  reviewer is asked for another.
- **Fail-closed checks.** `UnlentRejection`, and `substitute_type` meeting
  a parameter other than the default's `Self`, stop Check with a checker
  invariant. Neither should happen; an accepted test covers nested lambdas,
  a method value and a generic call whose type argument is not `Self`.
- **Specialization with a resource `Self`** is new. Opaque types erase to
  their underlying type, so nothing should change; landing 2's e2e fixture
  and its C will show it.

## Testing

Each rejection checks message, help, span and note; each test is proven by
breaking its rule.

- **Landing 1**, new suite
  `test/test_common/test_analysis/test_check/test_trait_purity.brp`:
  - accepted: impure requirements, defaults (calling `print`) and
    implementations; T2;
  - `ImplementationSignatureMismatch` for each purity mismatch (T1);
  - `ImpureCall` on a method from a pure function, default and lambda,
    through a bound, a concrete receiver, a name and a module alias;
  - `ImpureCallback` on a method; a stored impure method value keeps
    `p14`'s message; an impure expectation accepts both purities;
  - a pure generic may call a pure supertrait's method only;
  - `MalformedCanonicalTrait` for an impure canonical member;
    `MalformedCanonicalMember` for an impure `not_equals` and Orderable
    default (fixture libraries beside `fixtures/arithmetic_traits/`);
  - the reworded `ResourceImplementation` help;
  - e2e `test/test_compile/fixtures/effects/trait_methods.brp`: the `Logger`
    example, printing through a default and an override.
- **Landing 2**, in `test_resource_scopes.brp`:
  - accepted: an impure trait for `Token` with authored methods, defaults
    only or an impure supertrait; `token.mark()`; the method value; a
    default calling a method on `self`; the fail-closed case (Risks);
    defaults from another module and a library fixture; one default, two
    resources;
  - `ResourceContract`: a pure method, a supertrait's pure method, a pure
    default, a library trait (`Stringable`), `-> Self`, `-> List[Self]`,
    and the two renamed tests;
  - `InheritedDefault`, one test per route under "How" and "Written types",
    each with its help;
  - a bounded generic given a `Token` keeps the hardened message;
  - e2e `test/test_compile/fixtures/resources/traits.brp`: an authored method
    and an inherited default run inside `with_token`.
- **Landing 3:** each of the three helps for a resource, today's help for
  an ordinary receiver, and the supertrait-only fallback leading to
  `ResourceContract`.
- **Commands:** iterate with `make -C blorp test-target-components
  TARGET_COMPONENT_SOURCES=<suite>`; then `make -C blorp test`,
  `make -C blorp test-e2e INSTRUCTION_CHECK=on`,
  `scripts/blorp-fixpoint --prove` and
  `bash blorp/test/test_bootstrap/test_bootstrap.sh`.

## Acceptance criteria

- [ ] **Landing 1:** the Problem's `Sink` compiles; the e2e `Logger` prints
  its lines; `grep -rn 'ImpureRequirement\|trait methods are pure\|every
  trait method' blorp/src blorp/README.md` finds nothing; every test fails
  when its rule is removed; costs are within the ceilings; all gates pass.
- [ ] **Landing 2:** the proposed diagnostics hold; an impure `Sink` for
  `Writer` compiles; `grep -rn ResourceImplementation blorp/src blorp/test`
  finds nothing; the e2e fixture's C passes the resource as `int64_t`;
  costs are within the ceilings; all gates pass.
- [ ] **Landing 3:** for a resource, interpolation and a missing
  implementation name the trait's pure method, and a missing bound says a
  generic function cannot take it; costs are within the ceilings; all
  gates pass.

## Handback

Each landing returns its commit, gate logs, the self-compile table and
production and test lines. Stop and ask Keith when a ceiling fails, a route
escapes the lent walk, or a library trait wants an impure method.
