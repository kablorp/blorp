# Qualified constructor source-pattern pilot

**Status:** approved plan; source implementation and cost execution remain held.
No source migration or cost epoch is authorized by this document.

This plan starts from accepted main f1458924a1c6497e050c6960bcdfff3b985c5f2a,
whose compiler sources are byte-identical to db8abb15. Its implementation
prerequisite is the separately reviewed qualified-flat-head feature, represented
in this review by complete patch SHA256
`0ab25a7346d8365e554f2d1245270e5acc5e4b7107c4df1ddefc6d289a3a06c4`.
That feature has not landed on this base. The six function/line anchors and
before examples below refer to that exact feature candidate after its db8
alignment; `find_qualified_variant` exists only after the prerequisite lands.
Recheck anchors against its accepted integration before implementing this plan.
The dependency retains its own broad/cost acceptance and is not included in
this plan-only change.

The coordinator and independent reviewers approved this plan and its production,
test and fixture ceilings. Implementation remains held until the prerequisites
and gates below are satisfied. This change contains only this document and its
[roadmap](ROADMAP.md#m2b-pattern-compilation) link. No candidate module, SOURCE
freeze, source-migration compiler, cost sample or implementation has been
produced. Follow the [source plan](BOOTSTRAP_SOURCE_PLAN.md) and
[development instructions](AGENTS.md) when implementation is authorized.

## Purpose, authorities and boundary

After qualified-feature acceptance, use flat qualified heads on six real
checker producer/consumer paths. Replace nested constructor arm headers with successive matches while
retaining the exact existing branch actions. Qualification names the module that
DECLARES the constructor; it is not a spelling-based semantic lookup downstream.

- namespace/namespace.brp declares NamedValue, OfferedValue, Entity, TypeHead,
  SelectionProblem and Unoffered (lines173/181/55/39/129/120). Add `as Namespace`
  to its existing selected-import lines in constructors.brp and render.brp.
- utils/syntax.brp declares PatternHead, ParsedPattern and ParsedStatement
  (415/431/582). Add `as Syntax` to bodies.brp's existing selected import.
- Preserve the existing selected imports and existing Errors/Check aliases.
  Keep ordinary Ok/Err/Some/None from the designated foundation; do not qualify
  them through forwarding result/option modules that do not own the declarations.
- Existing full VariantId membership, occurrence_fields substitution, immutable
  VariantContract and resolve_variant_pattern remain the single authorities.
  No new helper, datatype, decision tree, registry, nested/list/literal feature,
  lower-stage name recovery or accepted-IR change is proposed.

## Accepted implementation base and region pins

The plan-review base `f1458924a` and old candidate line anchors are descriptive;
they are not an implementation or cost freeze. Before any source edit:

1. Obtain the coordinator's actual accepted-main commit and a region lease,
   after the qualified feature and any accepted M2/M3/opaque prerequisites.
   Record that full commit and the accepted qualified-feature commit. Rebuild
   the proposed source refactor from this actual base; never transplant an old
   function body or apply an old whole-function replacement.
2. Pin all three complete files and all six function regions: constructors.brp
   `find_declared_variant`/`find_qualified_variant`, bodies.brp
   `resolve_pattern`/`resolve_statements`, render.brp
   `declaration_span`/`render_selection`. For each region record actual path,
   function name, start/end byte offsets and SHA256 of the exact UTF-8 bytes,
   from its declaration through the final nonblank body line including the
   final newline. Do not substitute db8 hashes. If a prerequisite function is
   absent or any accepted base/region changes, stop and refresh before edits.
3. Refresh every before/after example against those six pinned regions. Build
   only the header/dispatch transformations below, preserving each current arm
   action verbatim except the required indentation and explicit constructor
   qualification. Keep all current signatures, call arguments, result carriers,
   diagnostics, branch order and fallback coverage. Recompute gross/net counts
   and retain the approved160/+40 production ceiling.
4. Preserve accepted M2 carrier-based statement/propagation handling,
   `BooleanContext.boolean`, M3 while admission and any newer type-head/note
   cases. Old `ReassignmentScope`, propagation rejection or while-rejection
   bodies from db8 are not implementations to copy. Compare the final branch
   actions against the pinned actual base, including call arguments and text.

All six actual region hashes are required before implementation; this plan does
not fabricate the missing accepted `find_qualified_variant` hash while the
feature remains unlanded. No SOURCE freeze or cost call is implied by these
static code pins. The independent review checks the refreshed dispatch-only
patch before implementation acceptance.

## Exact six sites and literate changes

### 1. constructors.brp:96, find_declared_variant

Before:
```blorp
match named_value(context.namespace, context.module, name.id):
    Some(NamedConstructor(variant)): declared_variant_contract(context, owner, variant, name.span)
    _: Ok(None)
```
After:
```blorp
match named_value(context.namespace, context.module, name.id):
    Some(named):
        match named:
            Namespace.NamedConstructor(variant): declared_variant_contract(context, owner, variant, name.span)
            _: Ok(None)
    None: Ok(None)
```

One namespace query, same visible declaration ID and same None result for a
nonconstructor. The existing find_variant fallback still owns the unimported-
constructor diagnostic; the full same_variant comparison is untouched.

### 2. constructors.brp:124, find_qualified_variant

Before:
```blorp
declared ?= match offered_value(context.namespace, aliased.target, qualified.name.id):
    Ok(OfferedConstructor(variant)):
        declared_variant_contract(context, occurrence.owner, variant, qualified.name.span)
    Ok(_): Ok(None)
    Err(reason):
        Err(qualified_error(qualified.name.span, QualifiedNotOffered(qualified.module.id, qualified.name.id, aliased.path, reason)))
```
After:
```blorp
declared ?= match offered_value(context.namespace, aliased.target, qualified.name.id):
    Ok(offered):
        match offered:
            Namespace.OfferedConstructor(variant):
                declared_variant_contract(context, occurrence.owner, variant, qualified.name.span)
            _: Ok(None)
    Err(reason):
        Err(qualified_error(qualified.name.span, QualifiedNotOffered(qualified.module.id, qualified.name.id, aliased.path, reason)))
```

Alias resolution still precedes the offer; private/non-reexport errors precede
membership/arity. Neither module alias nor constructor identity is reconstructed.
The existing instantiation and publication following this block are unchanged.

### 3. bodies.brp:183, resolve_pattern

The reviewed candidate has three Result/Option dispatches: a whole-arm bare
name, bare constructor head and qualified constructor head. Refresh each from
the accepted base. In the qualified branch, preserve the actual query and arm
actions and change these headers only:

Before:
```blorp
QualifiedHead(qualified):
    -- same accepted lookup and context arguments
    match found_result:
        Ok(Some(contract)):
            -- existing accepted-contract action
        Ok(None):
            -- existing exact missing-constructor diagnostic
        Err(error):
            -- existing error propagation
```
After:
```blorp
Syntax.QualifiedHead(qualified):
    -- same accepted lookup and context arguments
    match found_result:
        Ok(found):
            match found:
                Some(contract):
                    -- same accepted-contract action
                None:
                    -- same exact missing-constructor diagnostic
        Err(error):
            -- same error propagation
```

`found_result` labels the existing matched expression in these fragments; it is
not a proposed extra binding or helper. Qualify the function's existing flat
ParsedPattern and BareHead/QualifiedHead arms with Syntax. Preserve current
binding allocation, field order, capture types/origins/spans and publication of
VariantCase. The existing allocator, scope and context carriers remain unchanged,
including BooleanContext.boolean where the accepted base passes it.

### 4. bodies.brp:715, resolve_statements

Refresh from accepted current statement semantics. The transformation unwraps
the existing Option once, then dispatches its actual statement constructors.
Illustrative headers, with every accepted action retained:

Before:
```blorp
match selected_statement:
    None:
        -- current end-of-statements result/carrier
    Some(BindingStatement(binding)):
        -- current binding action
    Some(PropagatingBinding(propagation)):
        -- current propagation action
    Some(WhileLoop(loop)):
        -- current admitted while action
    -- current remaining statement arms
```
After:
```blorp
match selected_statement:
    None:
        -- same end-of-statements result/carrier
    Some(statement):
        match statement:
            Syntax.BindingStatement(binding):
                -- same binding action
            Syntax.PropagatingBinding(propagation):
                -- same propagation action
            Syntax.WhileLoop(loop):
                -- same admitted while action
            -- same remaining statement arms, qualified with Syntax
```

`selected_statement` labels the existing scrutinee, not a new binding. Retain the
current cursor/scrutinee exactly, all active M2 carriers and propagation, M3 while
handling, Boolean context arguments, initializer/collision priority, BindingIds
and append order. Do not copy the old unsupported-Propagation/While or
ReassignmentScope body. Reindent accepted actions; never replace the function.

### 5. render.brp:433, declaration_span

The reviewed candidate distinguishes Type(UnionHead(id)), Type(RecordHead(id))
and Type(candidate). Preserve every actual accepted type-head arm, including any
newer opaque head and its note lookup. Transform only outer/inner dispatch:

```blorp
Namespace.Type(candidate):
    match candidate:
        Namespace.UnionHead(id):
            -- same accepted union declaration-note action
        Namespace.RecordHead(id):
            -- same accepted record declaration-note action
        -- preserve any additional accepted type-head arms here
        _:
            -- same existing builtin/fallback action
```

Function/Constant/Constructor/Alias actions remain unchanged. Preserve nominal
IDs and existing inventory selection; no type spelling chooses the declaration
owner and no inventory is rebuilt.

### 6. render.brp:476, render_selection

The reviewed candidate has four nested NotOffered arms. Refresh their actual
set and actions, then match the existing reason once:

```blorp
Namespace.NotOffered(reason):
    match reason:
        Namespace.UnknownName:
            -- same selection-form-specific diagnostic
        Namespace.PrivateName:
            -- same private-declaration diagnostic
        Namespace.ImportedThere(entity):
            -- same help/type/declaration-note action
        Namespace.ProvidedThere(entity):
            -- same prelude diagnostic
```

Existing name/module spelling queries stay before this switch and run once.
Keep every current message/help/span/note and its first-error order. All other
SelectionProblem arms remain at the outer level. Strings here stay diagnostic
text without later-stage semantic meaning. Comments in these examples identify
unchanged accepted actions, not proposed helper calls or replacement bodies.

## Draft scope estimate and hard ceilings

An in-memory line-oriented draft of these six rewrites, including the three
same-line import aliases and ordinary readable indentation, gives:

| Production file | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| check/constructors.brp | 11 | 6 | +5 |
| check/bodies.brp | 53 | 45 | +8 |
| check/render.brp | 44 | 40 | +4 |
| Total | 108 | 91 | +17 |

This is an uncompiled estimate on the reviewed db8 candidate, not an
implemented/validated patch. Coordinator and independent design review approved
hard ceilings of160 gross added/+40 net production,240 added/+240 net tests and
zero new fixture lines. Refresh the estimate against the actual pinned base
before implementation; retain these caps if newer accepted arm actions increase
the draft. Plan approval does not authorize source edits. No compressed formatting, removed coverage or stacked pilot
allowances. This removes 21 nested arm headers at these six functions; it is not
a full compiler-source census or a claim that nested/list/literal dependencies
have all been removed. The qualified feature and this source refactor remain
separately reviewable/measurable changes.

## Characterization, acceptance, dependencies and stop rules

Use existing owning Blorp TestSuites first: test_check/{test_qualified_patterns,
test_match,test_binding_names,test_scope,test_constructors,test_qualified_names,
test_render}.brp and test_namespace/test_namespace.brp. Add only missing exact
characterizations within 240 lines: accepted VariantId and BindingIds 0/1 with
field type/origin/span; unknown/private/non-reexport errors; local initializer
and collision order; every current statement admission/rejection; UnionHead/RecordHead/
builtin declaration notes; selection-form help and imported/prelude notes.

Before source edits, characterize the unchanged baseline; source refactoring
should begin green. Demonstrate sensitive oracles with bounded semantic mutants
of the protected identity/priority/span, then restore exact bytes. Do not fabricate
an initial red or accept a host setup error as proof. After implementation run
focused owning suites, one current complete component/e2e acceptance, exact shared
C and diagnostics, strict zero pilot counters and normal-main sanitizer checks.

The source-refactor contract's +3% allocation and normal minimum-of-three
instruction ceilings apply to each unchanged owned input and the original
SOURCE checkpoint proxy, locally and cumulatively against the original reset
source baseline under the currently written policy. Freeze nothing and
claim no exception while the user's baseline-policy answer remains pending.
The separate qualified language feature is governed by its own tighter +3%
shared-input/original-checkpoint-proxy ceiling and 140,000 allocations / 500,000,000
instructions for its new fixture, compared against one accepted fixed B and
exact feature C with the same frozen host/workload. The original checkpoint is
the retained proxy workload; it does not by itself name an R0 baseline. The
[roadmap's feature/refactor contract](ROADMAP.md) applies original-reset
cumulative requirements to source migrations. This source pilot therefore
remains held for the policy decision independently of the feature's cost work.
No feature cap is relaxed here.

No measurements are authorized by this plan. The extra host control/capture
cost must be measured rather than assumed free; reject or rescope any hard
cost/LOC failure without deleting coverage or rolling the baseline.

Order after qualified-feature acceptance and the prerequisite accepted-source
alignment. Root must reserve these six regions in three checker files against
opaque/control writers and review the refreshed estimate before source edits. Stop on
source conflicts, unresolved ownership/diagnostic ordering, a new helper/model/
mechanism requirement, or a hard ceiling breach. No parse/namespace production,
specialization, lower/own/verify/emit or library change is part of this pilot.
