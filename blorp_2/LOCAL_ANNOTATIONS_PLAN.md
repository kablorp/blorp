# Local binding annotations

Status: EA3552 components, C/links and1098 native callbacks pass (495 cases).
All404 native budget rows pass; failed runs and the fixture correction are kept.
Fixed-e706 cost B/C is separate; all64 samples and547 oracle pairs pass.
Independent code and test-runner reviews approve this implementation and evidence.
Functional base `ea881c84d0df9df04a6ec5c4406a3b69cf406735`;
branch `codex/local-annotations-functional-ea`.
Historical author base `a9ea383cff354be0d3bd24639d9f614ffeb017ce` and staged candidate
`d3637a17f10b` remain separate, with original results and worktree preserved.

## Problem and shortest reproduction

The existing parser stores the annotation in ParsedBinding; no syntax change is
needed. At the e706 baseline, checking rejects it at check/bodies.brp:781-782:

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

The preserved baseline reports0 PASS/22 named FAIL, exit1 and empty stderr;
there was no setup failure or retry. The maintained scalar annotation fixture
passes native status7 with empty streams. The owning granular TestSuite is under
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

New-declaration checking currently resolves UntypedValue at bodies.brp:850:

```blorp
match resolve_value(block, written.initializer, UntypedValue, context):
```

A private initializer helper resolves the expectation at that boundary:

```blorp
expectation ?= match written.annotation:
    None: Ok(UntypedValue)
    Some(annotation):
        match resolve_type(context.body_types, annotation):
            Ok(value_type): Ok(CheckedAgainst(value_type, SourceAnnotation(type_span(annotation))))
            Err(error): Err(error)
resolve_value(block, written.initializer, expectation, context)
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
The complete-test forecast prospectively increases from560 to600 added before
the two post-RED preservation callbacks are written. Hard650 gross/+650 net
remains unchanged; at most2 ordinary fixtures,50 source lines total.
The plan's documentation ceiling prospectively increases from180 to220 physical
lines on2026-10-19; its reviewed preparation was179 lines. Other active docs
remain<=70 added; a retained benchmark report has a separate<=100-line ceiling.
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

On2026-10-19 root+independent review prospectively select the existing F4
six controls: pure/calls, ufcs/chain_64, generic/named/{identity,ordered,managed},
and return/zero, plus the original schema1 HOST proxy. FEATURE5% target/10% hard
and independent HOST3% apply per selected input. The16 early samples are reused;
the40 shared and8 C-only calls pass; the two new fixtures have no B denominator.
Oracle closure is496 file-backed+51 retained CLI states (32 generated/150 files,
16 preserved-output,3 usage):547 pairs; old annotation B rejects1/C compiles0,
with C realmain7. Native keeps all absolute caps; unit strings are not CLI requests.

Root owns lane leases and integration. Preserve all raw logs, complete diffs,
source/toolchain pins and failures under ignored build/. Request independent
compiler-expert code review and test-runner evidence before any implementation
commit, then complete root's final destination gates and landing. Stop for an
unresolved boundary, unavailable provenance, host defect, cap breach or a
need for another mechanism. Preserve this worktree; do not archive it.

## Current-port review boundary, 2026-10-19

The preserved22-case RED snapshot retains all20 original callbacks plus opaque
construction and scalar-constant cases. All22 failed in the single baseline run;
its raw source, outcomes and exact closing pins remain unchanged. After that
RED, the reviewed49-added/28-removed/+21 production and one observer port were
applied. The24-case suite then passed, as did both exact fault/restored-GREEN pairs.

The suite adds the two callbacks requested by independent review. A local
pure-function-type annotation must reject the complete FunctionType span, exact
message/help and no note before resolving unknown child types or its invalid RHS.
Plain assignment to an existing callable parameter must retain CallableAssignment,
its exact diagnostic/span and no note before checking an invalid RHS. This brings
the owning suite to24 callbacks; it does not add callable local-variable support.
Retain current callable assignment, opaque/constant fields and signature rules.
Historical +48/-27 production and20-case/mutation passes are not current-base proof.

The original planning base was not a frozen FEATURE B; its historical cost B/C/
proxy binding was unselected. Root now prospectively selects fixed accepted B
`e706b393d51038ba49af720999d308fd95ce4ea9` for this annotation slice. C must be
that base plus the complete annotation-only production, tests, fixtures and docs;
its compiler/library bytes are materialized. No historical denominator is relabeled.

ROOT std91 and the source-matched F3 producer have functional roles. They do not
replace the independently authoritative host-construction proxy. Root names
supporting normal producer6852 and diagnostic producera362; full binary/input
provenance and matching STD91 must be verified before any freeze. The proxy's
allocation metric is the unique schema1
`artifact_construction_complete.total_allocations` checkpoint. Normal retired
instructions use positive paired minimum-of-three samples. The independent
host-construction gate is prospectively+3% HARD under the parent data-model rule,
in addition to FEATURE+5% target/+10% hard and every tighter absolute fixture cap.

All64 selected samples and547 oracle pairs pass; source/library/image pins close.
EA3552 components and1098 native callbacks pass across495 cases and404 budget rows.
Earlier failures stay preserved. F4/F5 composition is separate from cost C.
Independent code and test-runner reviews approve this implementation and evidence.
No additional execution or publication is granted by these completed gates.
Report: benchmarks/results/blorp_2_local_annotations_2026-10-19.md.
