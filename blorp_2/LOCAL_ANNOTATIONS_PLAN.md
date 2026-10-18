# Local binding annotations

Status: root and independent compiler plan review APPROVE0. Production edits
follow the scheduled owning-suite RED; compiled lane grants stay separate. Base:
origin/main
`a9ea383cff354be0d3bd24639d9f614ffeb017ce`, isolated branch
`codex/local-binding-annotations`. No compiled jobs or cost setup have run.

## Problem and shortest reproduction

The existing parser stores the annotation in ParsedBinding; no syntax change is
needed. Checking currently rejects it at check/bodies.brp:757-758:

```blorp
match binding.annotation:
    Some(annotation): Err(unsupported_form(type_span(annotation), LocalAnnotation))
```

```blorp
pure func identity(value: Int) -> Int:
    answer: Int = value
    answer
func main() -> Int:
    identity(7)
```

Source inspection predicts `binding type annotations are not supported yet` at
the written Int; this is not an executed RED. Desired native result: status7,
empty stdout/stderr. The first feedback is a granular TestSuite under
test/unit/test_check/test_local_annotations.brp, using the existing parser/check
helpers and existing exact diagnostic conventions.

## Proposed solution and code

Reuse declarations.resolve_type and bodies.resolve_value(..., CheckedAgainst).
The signature checker already validates a TypeScope, including the function's
nominal TypeParameterIds. Retain that scope on the existing AcceptedFunction
as `body_types`, with `access = PrivateTypeUse`, and pass it through the existing
ResolutionContext. This is transient checking data: final CheckedFunction,
specialization, lowering, ownership, verification and runtime products do not
change. Do not repeat local_type_parameters, reconstruct ids from names, rebuild
declaration inventories per annotation, or introduce another inference engine.
PrivateTypeUse permits implementation-private types inside public bodies;
namespace imports and offered-type visibility remain the existing authority.

Owner/lifetime: namespace construction owns the frozen module/name authority;
resolve_signature owns its function-specific TypeScope and validates its generic
name-to-TypeParameterId bindings once. AcceptedFunction retains that completed
scope through body checking; ResolutionContext borrows the same immutable scope
while checking one function and its arms. CheckedFunction publication drops it.
Existing context.module/context.namespace remain compatibility projections for
current call/name APIs: construct them from accepted.body_types.module/namespace,
not independently. The stored values duplicate references, not resolution tables
or decisions; annotation resolution consumes context.body_types exclusively.
Do not refactor all existing consumers merely to remove those alias fields.

Narrow alternative: retain only scope.parameters on AcceptedFunction and build
one fresh body TypeScope. That needs the original raw RecordRow/UnionRow lists,
which ResolutionContext's CheckedRecord/CheckedUnion lists cannot substitute;
it adds separate inventory plumbing and a second six-field scope construction.
The full retained scope reuses the already-built value and needs no per-binding
or per-body inventory reconstruction. Choose it for this slice. Its extra
retained references/record copy and whole-checker cost must be measured later;
this is a simpler data path, not an asserted representation-cost win.

New-declaration checking currently resolves UntypedValue at bodies.brp:826:

```blorp
match resolve_value(block, written.initializer, UntypedValue, context):
```

The proposed expectation at that same boundary is:

```blorp
expectation ?= match written.annotation:
    None: Ok(UntypedValue)
    Some(annotation):
        value_type ?= resolve_type(context.body_types, annotation)
        Ok(CheckedAgainst(value_type, SourceAnnotation(type_span(annotation))))
match resolve_value(block, written.initializer, expectation, context):
```

Keep the original pre-binding scope, resolved binding/reassignment facts,
`binding_id(resolved.bindings.length())`, name span, mutability and bind_local
publication. A typed initializer match uses the existing accepted join path and
retains its M2 carried outputs. An annotation is an expected type, never a cast.

Root-resolved declaration and diagnostic rules:

* An annotated occurrence declares a binding, like explicit var.
  Existing-name collisions go through bind_local after initializer checking;
  annotation must not silently retype or shadow a visible mutable binding.
  Unannotated `name = value` keeps existing mutable/immutable assignment rules,
  error priority and InferredBindingDeclaration mismatch provenance.
* CheckedAgainst reports a value mismatch at the initializer span and retains
  SourceAnnotation(annotation span). Keep that established provenance, with
  exact primary, actual-value and annotation spans tested. The initial dispatch's
  declaration-span wording does not request a new primary location.
* Resolve the written type before the initializer. An unknown/invalid annotation
  wins over an invalid initializer; pin that competing-error case explicitly.

Remove the obsolete LocalAnnotation unsupported alternative/renderer only when
its complete checker path is replaced. No parser, runtime or ownership model,
general control workloop, if, ?=, while, new type, alias or public API is added.
The Boolean and M3 worktrees are independent; compose only reviewed final bytes.

## Tests and finite implementation sequence

After plan approval, write the new owning TestSuite before production changes;
request the shared compiled lane for its named baseline RED, then implement.
Use one callback per distinct invariant, with accepted typed data as the oracle:

1. Int annotation publishes exact BodyLocal/BindingId/type/name-span facts.
2. var annotation plus unannotated reassignment preserves identity and old aliases;
   immutable reassignment and changed-type reassignment retain exact errors.
3. Function-generic annotation reuses the exact function-owned parameter id.
4. List/nominal annotation supplies context to a zero-argument generic initializer
   and an empty List/nullary constructor; an unannotated control stays rejected.
5. Public body uses a private local nominal type; a qualified imported public type
   resolves normally, while unoffered/private imports keep exact typed errors.
6. Nominal mismatch, primitive mismatch, unknown type and competing initializer
   errors pin complete kind/message/help/primary/annotation spans and priority.
7. Self-initializer is unavailable; duplicate local/parameter/module names remain
   rejected; initializer-before-collision behavior remains explicit.
8. An annotated bound match reassigning an outer var preserves exact carried ids,
   old immutable aliases and original binding/value order.

Reuse the former local_annotation unsupported input as a real-main success and
add one contextual-generic List success; no alternate entrypoint or C rewriting.
Run the smallest new checker suite first, then existing bindings, bidirectional,
generic, private-type, join and record-admission owners. Root selects the finite
full components/e2e and source-matched pilot recipe after focused GREEN. Prove
the annotation/context oracle by restoring the original rejection and one typed
fault that bypasses the expectation; require named semantic failures, immediate
exact restore and restored GREEN. A setup failure is not a killed oracle.

## Numerical bounds, acceptance and handback

Forecast about50-70 added/10-20 removed production lines in signatures,
callables, bodies, errors and render; hard limits100 gross/+75 net production.
Tests forecast450-600 added, hard650 gross/+650 net; at most2 ordinary fixtures,
50 source lines total. Documentation: this plan<=180 lines, other edits<=70 added.
Report production/test/fixture counts separately; no compressed formatting,
deleted assertions, new carrier type or unrelated cleanup to fit a ceiling.

Proposed FEATURE cost limits: target<=+5%, hard<=+10% allocations and normal
minimum-of-three positive retired instructions per unchanged input, plus every
parent-required construction checkpoint and source proxy. Keep all stricter old
fixture limits; new tiny native cases propose30k allocations/180M instructions,
strict balanced counters, zero target leaks and ordinary sanitizers. Unchanged
supported inputs require exact C/status/diagnostics/output state. Enumerate the
old local-annotation rejection as the intended changed behavior; retain its
original bytes in the shared corpus. Numeric limits do not select a host role,
baseline, metric, proxy, corpus or epoch: root and independent review must agree
those explicitly before any preparation/freeze/sample. Do not substitute FULL
TOTAL or SOURCE3%, borrow another exception, roll B or shrink the corpus.

Root owns lane leases and integration. Preserve all raw logs, complete diffs,
source/toolchain pins and failures under ignored build/. Request independent
compiler-expert code review and test-runner evidence before any implementation
commit, then complete root's final destination gates and landing. Stop for an
unresolved boundary, unavailable provenance, host defect, cap breach or a
need for another mechanism. Preserve this worktree; do not archive it.
